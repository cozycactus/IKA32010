#!/usr/bin/env python3
"""Generate and compare ROM-free TMS32010 differential microtests.

The generated program is executable from the reset vector on a real TMS32010.
It initializes every physical data-RAM word through IN PA0, constructs a
reachable architectural state, executes a short constrained body, and emits a
fixed semantic dump.  No Eventide ROM data is required or embedded.

This v1 tool intentionally separates documented tests (``defined``) from
silicon-characterization probes.  Characterization results are recorded and
compared, but never count as gating failures.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


CAMPAIGN_SCHEMA = "ika32010-differential-1"
RESULT_SCHEMA = "ika32010-differential-result-1"
COMPARISON_SCHEMA = "ika32010-differential-comparison-1"
GENERATOR_VERSION = 1

DATA_WORDS = 0x90
PROGRAM_WORDS = 0x1000
STATUS_CAPTURE_ADDRESS = 0x8E
# TMS32010 Rev. B defines every SST output bit except bit 1, which Figure 2-7
# explicitly marks don't-care.  This still checks all five state fields and
# every documented fixed-one bit without imposing a later C1x convention.
STATUS_DEFINED_MASK = 0xFFFD

INIT_PORT = 0
CONTROL_PORT = 6
DUMP_PORT = 7
BEGIN_MAGIC = 0xC10F
DONE_MAGIC = 0xD00D

ACC_DUMP_OFFSET = DATA_WORDS
P_DUMP_OFFSET = ACC_DUMP_OFFSET + 2
T_DUMP_OFFSET = P_DUMP_OFFSET + 2
AR_DUMP_OFFSET = T_DUMP_OFFSET + 1
STACK_DUMP_OFFSET = AR_DUMP_OFFSET + 2
DUMP_WORDS = STACK_DUMP_OFFSET + 4

NOP = 0x7F80
DINT = 0x7F81
EINT = 0x7F82
ROVM = 0x7F8A
PAC = 0x7F8E
PUSH = 0x7F9C
POP = 0x7F9D
LARP0 = 0x6880
LDPK0 = 0x6E00
LDPK1 = 0x6E01

# Page-zero cells reserved by the generator.  The random body never chooses
# them as ordinary operands.  The complete RAM dump occurs before SCRATCH is
# reused by the destructive register/stack dump.
AR0_INIT = 0x70
AR1_INIT = 0x71
P_T_INIT = 0x72
P_M_INIT = 0x73
T_INIT = 0x74
ACC_HI_INIT = 0x75
ACC_LO_INIT = 0x76
STATUS_INIT = 0x77
STACK_INIT = (0x78, 0x79, 0x7A, 0x7B)
BEGIN_CELL = 0x7C
DONE_CELL = 0x7D
SCRATCH = 0x7E
TABLE_ADDRESS_CELL = 0x6D
TABLE_DATA_CELL = 0x6E
TABLE_PROGRAM_ADDRESS = 0x0300
TABLE_PROGRAM_SEED = 0xA55A
RESERVED_DATA = frozenset(
    {
        TABLE_ADDRESS_CELL,
        TABLE_DATA_CELL,
        AR0_INIT,
        AR1_INIT,
        P_T_INIT,
        P_M_INIT,
        T_INIT,
        ACC_HI_INIT,
        ACC_LO_INIT,
        STATUS_INIT,
        *STACK_INIT,
        BEGIN_CELL,
        DONE_CELL,
        SCRATCH,
        STATUS_CAPTURE_ADDRESS,
    }
)

_MASK64 = (1 << 64) - 1
_BOUNDARY16 = (
    0x0000,
    0x0001,
    0x0002,
    0x00FF,
    0x0100,
    0x0FFF,
    0x3FFF,
    0x4000,
    0x7FFF,
    0x8000,
    0x8001,
    0xFFFE,
    0xFFFF,
)


class FormatError(ValueError):
    """A campaign or result document violates the differential schema."""


class SplitMix64:
    """Tiny fully specified PRNG; results do not depend on Python's random API."""

    def __init__(self, seed: int) -> None:
        if type(seed) is not int or not 0 <= seed <= _MASK64:
            raise ValueError("seed must be an unsigned 64-bit integer")
        self.state = seed

    def next_u64(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) & _MASK64
        value = self.state
        value = ((value ^ (value >> 30)) * 0xBF58476D1CE4E5B9) & _MASK64
        value = ((value ^ (value >> 27)) * 0x94D049BB133111EB) & _MASK64
        return (value ^ (value >> 31)) & _MASK64

    def randbelow(self, bound: int) -> int:
        if type(bound) is not int or bound <= 0:
            raise ValueError("bound must be a positive integer")
        limit = (1 << 64) - ((1 << 64) % bound)
        while True:
            value = self.next_u64()
            if value < limit:
                return value % bound

    def choice(self, values: Sequence[Any]) -> Any:
        if not values:
            raise ValueError("cannot choose from an empty sequence")
        return values[self.randbelow(len(values))]

    def weighted_choice(self, values: Sequence[tuple[Any, int]]) -> Any:
        if not values or any(weight <= 0 for _, weight in values):
            raise ValueError("weighted choices need positive weights")
        pick = self.randbelow(sum(weight for _, weight in values))
        for value, weight in values:
            if pick < weight:
                return value
            pick -= weight
        raise AssertionError("unreachable weighted-choice tail")


@dataclass(slots=True)
class ProgramBuilder:
    words: list[int]

    def __init__(self) -> None:
        self.words = []

    @property
    def pc(self) -> int:
        return len(self.words)

    def emit(self, *words: int) -> int:
        origin = self.pc
        for word in words:
            if type(word) is not int or not 0 <= word <= 0xFFFF:
                raise ValueError(f"program word outside 16 bits: {word!r}")
            self.words.append(word)
        if len(self.words) > PROGRAM_WORDS:
            raise ValueError("generated program exceeds 4096 words")
        return origin


def _hex16(value: int) -> str:
    return f"0x{value & 0xFFFF:04x}"


def _hex12(value: int) -> str:
    return f"0x{value & 0x0FFF:03x}"


def _hex64(value: int) -> str:
    return f"0x{value & _MASK64:016x}"


def _canonical(value: Mapping[str, Any]) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def _case_digest(case_without_id: Mapping[str, Any]) -> str:
    return hashlib.sha256(_canonical(case_without_id).encode("utf-8")).hexdigest()


def _program_digest(words: Iterable[int]) -> str:
    payload = b"".join(int(word).to_bytes(2, "big") for word in words)
    return hashlib.sha256(payload).hexdigest()


def _parse_integer(value: object, *, bits: int | None = None) -> int:
    if type(value) is int:
        result = value
    elif isinstance(value, str):
        try:
            result = int(value, 0)
        except ValueError as error:
            raise FormatError(f"invalid integer {value!r}") from error
    else:
        raise FormatError(f"expected integer, got {type(value).__name__}")
    if result < 0 or (bits is not None and result >= 1 << bits):
        suffix = "" if bits is None else f" unsigned {bits}-bit"
        raise FormatError(f"integer {result!r} is outside{suffix} range")
    return result


def _random_word(rng: SplitMix64) -> int:
    if rng.randbelow(4) != 0:
        return rng.choice(_BOUNDARY16)
    return rng.next_u64() & 0xFFFF


def _random_initial_data(rng: SplitMix64) -> tuple[list[int], dict[str, Any]]:
    data = [_random_word(rng) for _ in range(DATA_WORDS)]

    # Keep eight random instructions' worth of +/- addressing away from page
    # boundaries and from the generator scratch block.
    ar0 = ((rng.next_u64() & 0xFE00) | (0x20 + rng.randbelow(0x21))) & 0xFFFF
    ar1 = ((rng.next_u64() & 0xFE00) | (0x40 + rng.randbelow(0x21))) & 0xFFFF
    p_t = _random_word(rng)
    p_m = _random_word(rng)
    t = _random_word(rng)
    acc_hi = _random_word(rng)
    acc_lo = _random_word(rng)
    ov = rng.randbelow(2)
    ovm = rng.randbelow(2)
    arp = rng.randbelow(2)
    dp = rng.randbelow(2)
    status = 0x1EFE | (ov << 15) | (ovm << 14) | (arp << 8) | dp
    stack = [rng.next_u64() & 0x0FFF for _ in range(4)]

    fixed = {
        TABLE_ADDRESS_CELL: TABLE_PROGRAM_ADDRESS,
        AR0_INIT: ar0,
        AR1_INIT: ar1,
        P_T_INIT: p_t,
        P_M_INIT: p_m,
        T_INIT: t,
        ACC_HI_INIT: acc_hi,
        ACC_LO_INIT: acc_lo,
        STATUS_INIT: status,
        BEGIN_CELL: BEGIN_MAGIC,
        DONE_CELL: DONE_MAGIC,
        SCRATCH: 0,
    }
    fixed.update(zip(STACK_INIT, stack, strict=True))
    for address, value in fixed.items():
        data[address] = value
    if data[TABLE_DATA_CELL] == TABLE_PROGRAM_SEED:
        data[TABLE_DATA_CELL] ^= 1

    return data, {
        "acc": f"0x{acc_hi:04x}{acc_lo:04x}",
        "ar0": _hex16(ar0),
        "ar1": _hex16(ar1),
        "arp": arp,
        "dp": dp,
        "intm": 1,
        "ov": ov,
        "ovm": ovm,
        "p_factors": [_hex16(p_t), _hex16(p_m)],
        "stack_push_order": [_hex12(value) for value in stack],
        "t": _hex16(t),
    }


def _emit_prologue(builder: ProgramBuilder) -> tuple[int, int]:
    start = builder.pc
    # RS leaves DP, ARP, and OVM unspecified on real TMS32010 silicon.  These
    # four instructions are therefore required before any RAM addressing.
    builder.emit(DINT, LDPK0, LARP0, ROVM)

    for address in range(0x80):
        builder.emit(0x4000 | address)  # IN direct, PA0, page 0
    builder.emit(LDPK1)
    for address in range(0x10):
        builder.emit(0x4000 | address)  # IN direct, PA0, physical page 1
    builder.emit(LDPK0)

    # Four pushes overwrite every physical stack level even if reset did not.
    for address in STACK_INIT:
        builder.emit(0x6600 | address, PUSH)  # ZALS value; PUSH low 12 bits

    builder.emit(0x3800 | AR0_INIT)  # LAR AR0
    builder.emit(0x3900 | AR1_INIT)  # LAR AR1
    builder.emit(0x6A00 | P_T_INIT)  # LT first product factor
    builder.emit(0x6D00 | P_M_INIT)  # MPY second factor
    builder.emit(NOP)  # keep the product pipeline and following state load separate
    builder.emit(0x6A00 | T_INIT)  # final T
    builder.emit(0x6500 | ACC_HI_INIT)  # ZALH
    builder.emit(0x6100 | ACC_LO_INIT)  # ADDS, exact unsigned low half
    builder.emit(LDPK0)
    builder.emit(0x7B00 | STATUS_INIT)  # LST sets OV/OVM/ARP/DP; not INTM
    return start, builder.pc


def _operand(builder: ProgramBuilder, rng: SplitMix64) -> tuple[int, list[int]]:
    # Direct operands deliberately stop at 0x0c.  A DMOV/LTD from 0x0d with
    # DP=1 would write the status-dump scratch at 0x8e and become invisible;
    # from 0x0f it would target undocumented logical address 0x90.
    if rng.randbelow(100) < 58:
        return rng.randbelow(0x0D), []

    # A previous random LAR/LARK may leave either AR anywhere in its 16-bit
    # range.  Re-seed the selected AR before every indirect instruction so a
    # defined-lane case never relies on the undocumented 0x90..0xff decode.
    setup_origin = builder.pc
    selected = rng.randbelow(2)
    safe_address = 0x20 + rng.randbelow(0x41)
    builder.emit(((0x70 | selected) << 8) | safe_address)
    builder.emit(0x6880 | selected)
    post = rng.choice((0x00, 0x10, 0x20))
    next_arp = rng.choice((0x00, 0x01, 0x08))
    return 0x80 | post | next_arp, builder.words[setup_origin : builder.pc]


_DEFINED_WEIGHTS: tuple[tuple[str, int], ...] = (
    ("subc", 16),
    ("sach", 13),
    ("lst", 11),
    ("dmov", 10),
    ("ltd", 10),
    ("tblr", 8),
    ("tblw", 8),
    ("fifth_pop", 8),
    ("sar", 9),
    ("abs", 7),
    ("add", 6),
    ("sub", 6),
    ("lac", 5),
    ("addh", 6),
    ("adds", 6),
    ("subh", 6),
    ("subs", 6),
    ("zalh", 4),
    ("zals", 4),
    ("sacl", 4),
    ("lar", 5),
    ("mar", 5),
    ("lt", 5),
    ("lta", 5),
    ("mpy", 6),
    ("mpyk", 7),
    ("and", 3),
    ("or", 4),
    ("xor", 4),
    ("pac", 3),
    ("apac", 5),
    ("spac", 5),
    ("lack", 3),
    ("lark", 4),
    ("larp", 4),
    ("ldp", 5),
    ("ldpk", 5),
    ("rovm", 3),
    ("sovm", 4),
    ("dint", 2),
    ("eint", 3),
    ("in", 3),
    ("out", 3),
    ("nop", 1),
    ("zac", 2),
    ("dmov_boundary_7f", 6),
)


def _emit_defined_instruction(
    builder: ProgramBuilder,
    rng: SplitMix64,
    in_stream: list[int],
) -> dict[str, Any]:
    mnemonic = rng.weighted_choice(_DEFINED_WEIGHTS)
    origin = builder.pc
    operand: int | None = None
    guard: list[int] = []
    address_setup: list[int] = []
    operation_offset: int | None = None

    no_operand = {
        "nop": NOP,
        "dint": DINT,
        "eint": EINT,
        "abs": 0x7F88,
        "zac": 0x7F89,
        "rovm": ROVM,
        "sovm": 0x7F8B,
        "pac": PAC,
        "apac": 0x7F8F,
        "spac": 0x7F90,
    }
    simple_high = {
        "sacl": 0x50,
        "addh": 0x60,
        "adds": 0x61,
        "subh": 0x62,
        "subs": 0x63,
        "subc": 0x64,
        "zalh": 0x65,
        "zals": 0x66,
        "mar": 0x68,
        "dmov": 0x69,
        "lt": 0x6A,
        "ltd": 0x6B,
        "lta": 0x6C,
        "mpy": 0x6D,
        "ldp": 0x6F,
        "xor": 0x78,
        "and": 0x79,
        "or": 0x7A,
        "lst": 0x7B,
    }

    if mnemonic in no_operand:
        builder.emit(no_operand[mnemonic])
    elif mnemonic == "fifth_pop":
        builder.emit(POP, POP, POP, POP, POP)
        operation_offset = 4
    elif mnemonic in {"add", "sub", "lac"}:
        operand, address_setup = _operand(builder, rng)
        shift = rng.randbelow(16)
        base = {"add": 0x00, "sub": 0x10, "lac": 0x20}[mnemonic]
        builder.emit(((base + shift) << 8) | operand)
    elif mnemonic in {"sar", "lar"}:
        operand, address_setup = _operand(builder, rng)
        auxiliary = rng.randbelow(2)
        base = 0x30 if mnemonic == "sar" else 0x38
        builder.emit(((base | auxiliary) << 8) | operand)
    elif mnemonic == "sach":
        operand, address_setup = _operand(builder, rng)
        shift = rng.choice((0, 1, 4))
        builder.emit(((0x58 | shift) << 8) | operand)
    elif mnemonic in {"in", "out"}:
        operand, address_setup = _operand(builder, rng)
        port = 1 + rng.randbelow(5)  # PA6/PA7 are dump framing ports
        high = (0x40 if mnemonic == "in" else 0x48) | port
        builder.emit((high << 8) | operand)
        if mnemonic == "in":
            value = _random_word(rng)
            in_stream.append(value)
    elif mnemonic in {"tblr", "tblw"}:
        operand = TABLE_DATA_CELL
        builder.emit(LDPK0, 0x6600 | TABLE_ADDRESS_CELL)
        builder.emit((0x6700 if mnemonic == "tblr" else 0x7D00) | operand)
        operation_offset = 2
    elif mnemonic in simple_high:
        operand, address_setup = _operand(builder, rng)
        builder.emit((simple_high[mnemonic] << 8) | operand)
        if mnemonic == "subc":
            # TI specifies that the immediately following instruction cannot
            # use ACC.  A NOP makes every randomly composed sequence legal and
            # lets the delayed SUBC result settle before the next target.
            builder.emit(NOP)
            guard.append(NOP)
    elif mnemonic == "lark":
        auxiliary = rng.randbelow(2)
        builder.emit(((0x70 | auxiliary) << 8) | (rng.next_u64() & 0xFF))
    elif mnemonic == "larp":
        builder.emit(0x6880 | rng.randbelow(2))
    elif mnemonic == "ldpk":
        builder.emit(0x6E00 | rng.randbelow(2))
    elif mnemonic == "lack":
        builder.emit(0x7E00 | (rng.next_u64() & 0xFF))
    elif mnemonic == "mpyk":
        immediate = rng.choice((-4096, -1, 0, 1, 4095, rng.randbelow(8192) - 4096))
        builder.emit(0x8000 | (immediate & 0x1FFF))
    elif mnemonic == "dmov_boundary_7f":
        # 0x7f -> 0x80 is the documented page boundary.  The separate
        # characterization lane covers 0x8f -> logical 0x90 alias behavior.
        builder.emit(LDPK0, 0x697F)
    else:
        raise AssertionError(f"unhandled defined mnemonic {mnemonic}")

    emitted = builder.words[origin : builder.pc]
    if operation_offset is None:
        operation_offset = 1 if mnemonic == "dmov_boundary_7f" else len(address_setup)
    result: dict[str, Any] = {
        "mnemonic": mnemonic,
        "operation_offset": operation_offset,
        "origin": _hex12(origin),
        "words": [_hex16(word) for word in emitted],
    }
    if operand is not None:
        result["operand"] = _hex16(operand)
    if address_setup:
        result["address_setup"] = [_hex16(word) for word in address_setup]
    if guard:
        result["subc_guard"] = [_hex16(word) for word in guard]
    return result


_CHARACTERIZATION_KINDS = (
    "sach_reserved_shift_2",
    "sach_reserved_shift_3",
    "sach_reserved_shift_5",
    "sach_reserved_shift_6",
    "sach_reserved_shift_7",
    "dmov_page1_8f_to_90",
    "ltd_page1_8f_to_90",
    "direct_page1_alias_90",
    "ldpk_reserved_2",
    "indirect_inc_and_dec",
    "branch_nonzero_low_byte",
    "reserved_opcode_3200",
)


def _emit_characterization(
    builder: ProgramBuilder,
    rng: SplitMix64,
    index: int,
) -> dict[str, Any]:
    del rng  # index rotation guarantees corpus coverage independently of chance
    kind = _CHARACTERIZATION_KINDS[index % len(_CHARACTERIZATION_KINDS)]
    origin = builder.pc
    if kind.startswith("sach_reserved_shift_"):
        shift = int(kind.rsplit("_", 1)[1])
        builder.emit(((0x58 | shift) << 8) | 0x01)
    elif kind == "dmov_page1_8f_to_90":
        builder.emit(LDPK1, 0x690F)
    elif kind == "ltd_page1_8f_to_90":
        builder.emit(LDPK1, 0x6B0F)
    elif kind == "direct_page1_alias_90":
        builder.emit(LDPK1, 0x2010)
    elif kind == "ldpk_reserved_2":
        builder.emit(0x6E02)
    elif kind == "indirect_inc_and_dec":
        builder.emit(0x20B8)
    elif kind == "branch_nonzero_low_byte":
        builder.emit(0xF901, (builder.pc + 2) & 0x0FFF)
    elif kind == "reserved_opcode_3200":
        builder.emit(0x3200)
    else:
        raise AssertionError(f"unhandled characterization kind {kind}")
    return {
        "characterization": kind,
        "mnemonic": kind.split("_", 1)[0],
        "origin": _hex12(origin),
        "words": [_hex16(word) for word in builder.words[origin : builder.pc]],
    }


def _emit_epilogue(builder: ProgramBuilder) -> tuple[int, int, int]:
    start = builder.pc
    builder.emit(0x7C0E)  # SST direct always writes physical page-1 cell 0x8e
    builder.emit(LDPK0)
    builder.emit(((0x48 | CONTROL_PORT) << 8) | BEGIN_CELL)

    for address in range(0x80):
        builder.emit(((0x48 | DUMP_PORT) << 8) | address)
    builder.emit(LDPK1)
    for address in range(0x10):
        builder.emit(((0x48 | DUMP_PORT) << 8) | address)
    builder.emit(LDPK0)

    dump_scratch = ((0x48 | DUMP_PORT) << 8) | SCRATCH
    builder.emit(0x5800 | SCRATCH, dump_scratch)  # ACC high
    builder.emit(0x5000 | SCRATCH, dump_scratch)  # ACC low

    builder.emit(PAC)
    builder.emit(0x5800 | SCRATCH, dump_scratch)  # P high
    builder.emit(0x5000 | SCRATCH, dump_scratch)  # P low

    # TI User's Guide context-save sequence: MPYK 1; PAC exposes T through P.
    builder.emit(0x8001, PAC, 0x5000 | SCRATCH, dump_scratch)

    builder.emit(0x3000 | SCRATCH, dump_scratch)  # SAR AR0
    builder.emit(0x3100 | SCRATCH, dump_scratch)  # SAR AR1

    for _ in range(4):
        builder.emit(POP, 0x5000 | SCRATCH, dump_scratch)

    builder.emit(((0x48 | CONTROL_PORT) << 8) | DONE_CELL)
    halt = builder.pc
    builder.emit(0xF900, halt)  # B halt
    return start, halt, builder.pc


def _dump_schema() -> dict[str, Any]:
    return {
        "begin": {"port": CONTROL_PORT, "value": _hex16(BEGIN_MAGIC)},
        "done": {"port": CONTROL_PORT, "value": _hex16(DONE_MAGIC)},
        "fields": [
            {"name": "ram", "offset": 0, "words": DATA_WORDS},
            {
                "name": "status",
                "mask": _hex16(STATUS_DEFINED_MASK),
                "offset": STATUS_CAPTURE_ADDRESS,
                "words": 1,
            },
            {"name": "acc", "offset": ACC_DUMP_OFFSET, "words": 2},
            {"name": "p", "offset": P_DUMP_OFFSET, "words": 2},
            {"name": "t", "offset": T_DUMP_OFFSET, "words": 1},
            {"name": "ar0", "offset": AR_DUMP_OFFSET, "words": 1},
            {"name": "ar1", "offset": AR_DUMP_OFFSET + 1, "words": 1},
            {
                "name": "stack_top_to_bottom",
                "offset": STACK_DUMP_OFFSET,
                "words": 4,
            },
        ],
        "ram_status_scratch": _hex16(STATUS_CAPTURE_ADDRESS),
        "value_port": DUMP_PORT,
        "word_count": DUMP_WORDS,
    }


def _make_case(case_seed: int, index: int, lane: str) -> dict[str, Any]:
    rng = SplitMix64(case_seed)
    initial_data, initial_state = _random_initial_data(rng)
    in_stream = list(initial_data)
    builder = ProgramBuilder()
    prologue_start, prologue_end = _emit_prologue(builder)
    body_start = builder.pc

    if lane == "defined":
        body_count = 1 + rng.randbelow(8)
        body = [
            _emit_defined_instruction(builder, rng, in_stream)
            for _ in range(body_count)
        ]
    elif lane == "characterization":
        body = [_emit_characterization(builder, rng, index)]
    else:
        raise ValueError(f"unsupported case lane {lane!r}")

    body_end = builder.pc
    epilogue_start, halt, end = _emit_epilogue(builder)
    uses_table_scratch = any(
        instruction["mnemonic"] in {"tblr", "tblw"} for instruction in body
    )
    if uses_table_scratch:
        if builder.pc > TABLE_PROGRAM_ADDRESS:
            raise ValueError("generated executable overlaps table scratch")
        while builder.pc < TABLE_PROGRAM_ADDRESS:
            builder.emit(NOP)
        builder.emit(TABLE_PROGRAM_SEED)
    words = tuple(builder.words)
    program: dict[str, Any] = {
        "origin": "0x0000",
        "sha256": _program_digest(words),
        "word_count": len(words),
        "words": [_hex16(word) for word in words],
    }
    if uses_table_scratch:
        program["table_scratch"] = {
            "address": _hex12(TABLE_PROGRAM_ADDRESS),
            "initial_value": _hex16(TABLE_PROGRAM_SEED),
        }
    case_without_id: dict[str, Any] = {
        "body": body,
        "case_seed": _hex64(case_seed),
        "constraints": {
            "body_instruction_limit": 8,
            "documented_encodings_only": lane == "defined",
            "full_ram_initialized_via_in": True,
            "initial_stack_pushes": 4,
            "subc_followed_by_non_acc_nop": True,
            "tblw_target_is_nonexecuted_scratch": True,
        },
        "dump": _dump_schema(),
        "index": index,
        "initial_data": [_hex16(word) for word in initial_data],
        "initial_state": initial_state,
        "input_stream": [_hex16(word) for word in in_stream],
        "lane": lane,
        "layout": {
            "body": [_hex12(body_start), _hex12(body_end)],
            "end_exclusive": _hex12(end),
            "epilogue": [_hex12(epilogue_start), _hex12(halt)],
            "halt": _hex12(halt),
            "prologue": [_hex12(prologue_start), _hex12(prologue_end)],
        },
        "program": program,
    }
    return {"case_id": _case_digest(case_without_id), **case_without_id}


def generate_campaign(seed: int, count: int, lane: str = "defined") -> dict[str, Any]:
    """Return a deterministic campaign manifest."""
    if type(count) is not int or count <= 0:
        raise ValueError("count must be a positive integer")
    if lane not in {"defined", "characterization", "mixed"}:
        raise ValueError("lane must be defined, characterization, or mixed")
    rng = SplitMix64(seed)
    cases = []
    for index in range(count):
        case_lane = (
            ("defined" if index % 4 != 3 else "characterization")
            if lane == "mixed"
            else lane
        )
        cases.append(_make_case(rng.next_u64(), index, case_lane))
    return {
        "case_count": count,
        "cases": cases,
        "generator_version": GENERATOR_VERSION,
        "requested_lane": lane,
        "schema": CAMPAIGN_SCHEMA,
        "seed": _hex64(seed),
    }


def _validate_campaign(document: Mapping[str, Any]) -> dict[str, Mapping[str, Any]]:
    if document.get("schema") != CAMPAIGN_SCHEMA:
        raise FormatError(f"manifest schema must be {CAMPAIGN_SCHEMA!r}")
    cases = document.get("cases")
    if not isinstance(cases, list) or not cases:
        raise FormatError("manifest cases must be a non-empty list")
    result: dict[str, Mapping[str, Any]] = {}
    for case in cases:
        if not isinstance(case, Mapping):
            raise FormatError("manifest case must be an object")
        case_id = case.get("case_id")
        if not isinstance(case_id, str) or len(case_id) != 64:
            raise FormatError("manifest case_id must be a SHA-256 string")
        try:
            int(case_id, 16)
        except ValueError as error:
            raise FormatError("manifest case_id must be a SHA-256 string") from error
        without_id = dict(case)
        without_id.pop("case_id", None)
        if _case_digest(without_id) != case_id:
            raise FormatError(f"manifest case {case_id} does not match its content hash")

        program = case.get("program")
        if not isinstance(program, Mapping):
            raise FormatError(f"manifest case {case_id} has no program object")
        encoded = program.get("words")
        if not isinstance(encoded, list):
            raise FormatError(f"manifest case {case_id} program words must be a list")
        program_words = [_parse_integer(word, bits=16) for word in encoded]
        if program.get("word_count") != len(program_words):
            raise FormatError(f"manifest case {case_id} program word count is invalid")
        if program.get("sha256") != _program_digest(program_words):
            raise FormatError(f"manifest case {case_id} program SHA-256 is invalid")
        if case_id in result:
            raise FormatError(f"duplicate manifest case {case_id}")
        result[case_id] = case
    return result


def _result_cases(document: Mapping[str, Any]) -> tuple[str, dict[str, Mapping[str, Any]]]:
    if document.get("schema") != RESULT_SCHEMA:
        raise FormatError(f"result schema must be {RESULT_SCHEMA!r}")
    oracle = document.get("oracle")
    if not isinstance(oracle, str) or not oracle:
        raise FormatError("result oracle must be a non-empty string")
    cases = document.get("cases")
    if not isinstance(cases, list):
        raise FormatError("result cases must be a list")
    result: dict[str, Mapping[str, Any]] = {}
    for case in cases:
        if not isinstance(case, Mapping) or not isinstance(case.get("case_id"), str):
            raise FormatError("result case must contain case_id")
        case_id = str(case["case_id"])
        if case_id in result:
            raise FormatError(f"duplicate result case {case_id} for {oracle}")
        result[case_id] = case
    return oracle, result


def _normalized_result(case: Mapping[str, Any]) -> dict[str, Any]:
    status = case.get("status")
    if not isinstance(status, str) or not status:
        raise FormatError("result status must be a non-empty string")
    normalized: dict[str, Any] = {"status": status}
    if status == "ok":
        dump = case.get("dump")
        if not isinstance(dump, list) or len(dump) != DUMP_WORDS:
            raise FormatError(f"ok result dump must contain {DUMP_WORDS} words")
        words = [_parse_integer(word, bits=16) for word in dump]
        words[STATUS_CAPTURE_ADDRESS] &= STATUS_DEFINED_MASK
        normalized["dump"] = words

    if status == "ok":
        dirty = case.get("program_dirty")
        if not isinstance(dirty, list):
            raise FormatError("ok result program_dirty must be a list")
        pairs = []
        for item in dirty:
            if not isinstance(item, Mapping):
                raise FormatError("program_dirty entries must be objects")
            pairs.append(
                (
                    _parse_integer(item.get("address"), bits=12),
                    _parse_integer(item.get("value"), bits=16),
                )
            )
        if len({address for address, _ in pairs}) != len(pairs):
            raise FormatError("program_dirty must contain final unique addresses")
        normalized["program_dirty"] = sorted(pairs)

        body_outputs = case.get("body_outputs")
        if not isinstance(body_outputs, list):
            raise FormatError("ok result body_outputs must be a list")
        normalized["body_outputs"] = body_outputs
    else:
        normalized["program_dirty"] = []
        normalized["body_outputs"] = []
    if "cycles" in case:
        normalized["cycles"] = _parse_integer(case["cycles"])
    return normalized


def _dump_field(index: int) -> str:
    if index < DATA_WORDS:
        return "status" if index == STATUS_CAPTURE_ADDRESS else f"ram[{index:#04x}]"
    if index < P_DUMP_OFFSET:
        return ("acc_hi", "acc_lo")[index - ACC_DUMP_OFFSET]
    if index < T_DUMP_OFFSET:
        return ("p_hi", "p_lo")[index - P_DUMP_OFFSET]
    if index == T_DUMP_OFFSET:
        return "t"
    if index == AR_DUMP_OFFSET:
        return "ar0"
    if index == AR_DUMP_OFFSET + 1:
        return "ar1"
    return f"stack[{index - STACK_DUMP_OFFSET}]"


def _first_mismatch(values: Mapping[str, Mapping[str, Any]]) -> dict[str, Any] | None:
    if len(values) < 2:
        return None
    oracles = sorted(values)
    statuses = {oracle: values[oracle]["status"] for oracle in oracles}
    if len(set(statuses.values())) != 1:
        return {"field": "status", "values": statuses}
    if next(iter(statuses.values())) == "ok":
        dumps = {oracle: values[oracle]["dump"] for oracle in oracles}
        for index in range(DUMP_WORDS):
            field_values = {oracle: _hex16(dumps[oracle][index]) for oracle in oracles}
            if len(set(field_values.values())) != 1:
                return {
                    "dump_index": index,
                    "field": _dump_field(index),
                    "values": field_values,
                }
    for field in ("program_dirty", "body_outputs"):
        field_values = {oracle: values[oracle][field] for oracle in oracles}
        if len({_canonical({"value": value}) for value in field_values.values()}) != 1:
            return {"field": field, "values": field_values}
    if all("cycles" in values[oracle] for oracle in oracles):
        cycles = {oracle: values[oracle]["cycles"] for oracle in oracles}
        if len(set(cycles.values())) != 1:
            return {"field": "cycles", "values": cycles}
    return None


def compare_campaign(
    manifest: Mapping[str, Any],
    results: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    """Normalize and compare two or more oracle result documents."""
    manifest_cases = _validate_campaign(manifest)
    if len(results) < 2:
        raise FormatError("comparison needs results from at least two oracles")
    result_sets: dict[str, dict[str, Mapping[str, Any]]] = {}
    for document in results:
        oracle, cases = _result_cases(document)
        if oracle in result_sets:
            raise FormatError(f"duplicate result oracle {oracle!r}")
        unknown = set(cases) - set(manifest_cases)
        if unknown:
            raise FormatError(f"{oracle} contains unknown case {sorted(unknown)[0]}")
        result_sets[oracle] = cases

    compared = []
    defined_failures = 0
    characterization_differences = 0
    execution_failures = 0
    incomplete = 0
    for case_id, manifest_case in manifest_cases.items():
        available: dict[str, Mapping[str, Any]] = {}
        missing = []
        for oracle, cases in result_sets.items():
            if case_id not in cases:
                missing.append(oracle)
            else:
                available[oracle] = _normalized_result(cases[case_id])

        lane = str(manifest_case.get("lane"))
        gating = lane == "defined"
        entry: dict[str, Any] = {
            "case_id": case_id,
            "gating": gating,
            "lane": lane,
            "oracles": sorted(available),
        }
        if missing:
            entry["classification"] = "incomplete"
            entry["missing"] = sorted(missing)
            incomplete += 1
            if gating:
                defined_failures += 1
        else:
            groups: dict[str, list[str]] = {}
            # Cycle counts are useful when every adapter reports them.  Do not
            # turn an otherwise equal semantic dump into a mismatch merely
            # because an early silicon adapter omits this optional field.
            if not all("cycles" in value for value in available.values()):
                for value in available.values():
                    if isinstance(value, dict):
                        value.pop("cycles", None)
            for oracle, value in available.items():
                key = _canonical(value)
                groups.setdefault(key, []).append(oracle)
            public_groups = sorted((sorted(group) for group in groups.values()), key=lambda x: x)
            entry["equal_groups"] = public_groups
            statuses = {value["status"] for value in available.values()}
            has_execution_failure = any(status != "ok" for status in statuses)
            unanimous_failure = len(statuses) == 1 and has_execution_failure
            if unanimous_failure:
                entry["classification"] = f"all_failed:{next(iter(statuses))}"
                entry["execution_status"] = next(iter(statuses))
            elif len(groups) == 1:
                entry["classification"] = "all_equal"
            elif len(available) == 3 and sorted(map(len, groups.values())) == [1, 2]:
                outlier = next(group[0] for group in public_groups if len(group) == 1)
                entry["classification"] = f"outlier:{outlier}"
            elif len(groups) == len(available):
                entry["classification"] = "all_different"
            else:
                entry["classification"] = "mismatch"
            mismatch = _first_mismatch(available)
            if mismatch is not None:
                entry["first_mismatch"] = mismatch
                if not gating:
                    characterization_differences += 1
            if has_execution_failure:
                execution_failures += 1
            if gating and (has_execution_failure or mismatch is not None):
                defined_failures += 1
        compared.append(entry)

    return {
        "cases": compared,
        "oracles": sorted(result_sets),
        "schema": COMPARISON_SCHEMA,
        "summary": {
            "case_count": len(compared),
            "characterization_differences": characterization_differences,
            "defined_failures": defined_failures,
            "execution_failures": execution_failures,
            "incomplete": incomplete,
        },
    }


def _read_document(path: str | Path) -> Mapping[str, Any]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise FormatError(f"cannot read JSON document {path}: {error}") from error
    if not isinstance(value, Mapping):
        raise FormatError(f"JSON document {path} must contain an object")
    return value


def _write_document(value: Mapping[str, Any], output: str | None) -> None:
    text = json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    if output is None or output == "-":
        sys.stdout.write(text)
    else:
        Path(output).write_text(text, encoding="utf-8")


def _seed(value: str) -> int:
    try:
        seed = int(value, 0)
    except ValueError as error:
        raise argparse.ArgumentTypeError("seed must be an integer") from error
    if not 0 <= seed <= _MASK64:
        raise argparse.ArgumentTypeError("seed must fit unsigned 64 bits")
    return seed


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    generate = subparsers.add_parser("generate", help="generate a campaign manifest")
    generate.add_argument("--seed", type=_seed, required=True)
    generate.add_argument("--count", type=int, default=100)
    generate.add_argument(
        "--lane",
        choices=("defined", "characterization", "mixed"),
        default="defined",
    )
    generate.add_argument("--output", help="output JSON path, or - for stdout")

    compare = subparsers.add_parser("compare", help="compare oracle result files")
    compare.add_argument("--manifest", required=True)
    compare.add_argument("--result", action="append", required=True)
    compare.add_argument("--output", help="output JSON path, or - for stdout")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "generate":
            document = generate_campaign(arguments.seed, arguments.count, arguments.lane)
            _write_document(document, arguments.output)
            return 0
        manifest = _read_document(arguments.manifest)
        result_documents = [_read_document(path) for path in arguments.result]
        comparison = compare_campaign(manifest, result_documents)
        _write_document(comparison, arguments.output)
        return 1 if comparison["summary"]["defined_failures"] else 0
    except (FormatError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
