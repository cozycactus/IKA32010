#!/usr/bin/env python3
"""Unit tests for the ROM-free differential campaign generator."""

from __future__ import annotations

import hashlib
import json
import unittest

from tools.tms32010_differential import (
    BEGIN_CELL,
    CAMPAIGN_SCHEMA,
    CONTROL_PORT,
    DATA_WORDS,
    DUMP_PORT,
    DUMP_WORDS,
    FormatError,
    LARP0,
    LDPK0,
    LDPK1,
    NOP,
    POP,
    RESULT_SCHEMA,
    ROVM,
    STACK_DUMP_OFFSET,
    STATUS_CAPTURE_ADDRESS,
    STATUS_DEFINED_MASK,
    TABLE_ADDRESS_CELL,
    TABLE_DATA_CELL,
    TABLE_PROGRAM_ADDRESS,
    TABLE_PROGRAM_SEED,
    compare_campaign,
    generate_campaign,
)


def words(case: dict[str, object]) -> list[int]:
    program = case["program"]
    assert isinstance(program, dict)
    encoded = program["words"]
    assert isinstance(encoded, list)
    return [int(value, 0) for value in encoded]


def result(
    oracle: str,
    cases: list[dict[str, object]],
    *,
    delta_index: int | None = None,
    delta: int = 1,
) -> dict[str, object]:
    records = []
    for case in cases:
        dump = [0] * DUMP_WORDS
        if delta_index is not None:
            dump[delta_index] ^= delta
        records.append(
            {
                "case_id": case["case_id"],
                "body_outputs": [],
                "dump": [f"0x{value:04x}" for value in dump],
                "program_dirty": [],
                "status": "ok",
            }
        )
    return {"cases": records, "oracle": oracle, "schema": RESULT_SCHEMA}


class GeneratorTests(unittest.TestCase):
    def test_seed_is_reproducible_and_manifest_ids_are_content_hashes(self) -> None:
        first = generate_campaign(0x123456789ABCDEF0, 12, "mixed")
        second = generate_campaign(0x123456789ABCDEF0, 12, "mixed")
        different = generate_campaign(0x123456789ABCDEF1, 12, "mixed")
        self.assertEqual(first, second)
        self.assertNotEqual(first, different)
        self.assertEqual(first["schema"], CAMPAIGN_SCHEMA)

        for case in first["cases"]:
            without_id = dict(case)
            case_id = without_id.pop("case_id")
            canonical = json.dumps(
                without_id,
                ensure_ascii=False,
                allow_nan=False,
                separators=(",", ":"),
                sort_keys=True,
            )
            self.assertEqual(case_id, hashlib.sha256(canonical.encode()).hexdigest())

    def test_prologue_is_reachable_and_initializes_all_144_ram_words(self) -> None:
        case = generate_campaign(7, 1, "defined")["cases"][0]
        program = words(case)
        prologue_start, prologue_end = (
            int(value, 0) for value in case["layout"]["prologue"]
        )
        prologue = program[prologue_start:prologue_end]
        self.assertEqual(prologue[:4], [0x7F81, LDPK0, LARP0, ROVM])

        self.assertEqual(prologue[4 : 4 + 0x80], list(range(0x4000, 0x4080)))
        page_one = 4 + 0x80
        self.assertEqual(prologue[page_one], LDPK1)
        self.assertEqual(
            prologue[page_one + 1 : page_one + 17], list(range(0x4000, 0x4010))
        )
        self.assertEqual(len(case["initial_data"]), DATA_WORDS)
        self.assertGreaterEqual(len(case["input_stream"]), DATA_WORDS)
        self.assertEqual(
            case["input_stream"][:DATA_WORDS], case["initial_data"]
        )
        self.assertEqual(prologue.count(0x7F9C), 4)

    def test_epilogue_has_fixed_dump_and_ti_context_save_sequence(self) -> None:
        case = generate_campaign(19, 1, "defined")["cases"][0]
        program = words(case)
        epilogue_start = int(case["layout"]["epilogue"][0], 0)
        halt = int(case["layout"]["halt"], 0)
        epilogue = program[epilogue_start:halt]

        self.assertEqual(epilogue[:2], [0x7C0E, LDPK0])
        self.assertEqual(
            epilogue[2], ((0x48 | CONTROL_PORT) << 8) | BEGIN_CELL
        )
        self.assertEqual(sum(word >> 8 == (0x48 | DUMP_PORT) for word in epilogue), 155)
        self.assertEqual(epilogue.count(POP), 4)
        self.assertIn([0x8001, 0x7F8E], [epilogue[i : i + 2] for i in range(len(epilogue) - 1)])
        self.assertEqual(case["dump"]["word_count"], DUMP_WORDS)
        status = next(
            field for field in case["dump"]["fields"] if field["name"] == "status"
        )
        self.assertEqual(status["offset"], STATUS_CAPTURE_ADDRESS)
        self.assertEqual(int(status["mask"], 0), STATUS_DEFINED_MASK)

    def test_defined_lane_uses_only_legal_sach_shifts_and_guards_subc(self) -> None:
        campaign = generate_campaign(0xD1FF, 200, "defined")
        seen_subc = False
        seen_sach = False
        seen_fifth_pop = False
        for case in campaign["cases"]:
            self.assertEqual(case["lane"], "defined")
            for instruction in case["body"]:
                encoded = [int(value, 0) for value in instruction["words"]]
                operation = encoded[instruction["operation_offset"]]
                if "operand" in instruction:
                    operand = int(instruction["operand"], 0)
                    setup = [
                        int(value, 0)
                        for value in instruction.get("address_setup", [])
                    ]
                    if instruction["mnemonic"] in {"tblr", "tblw"}:
                        self.assertEqual(operand, TABLE_DATA_CELL)
                    elif operand & 0x80:
                        self.assertEqual(len(setup), 2)
                        self.assertIn(setup[0] >> 8, {0x70, 0x71})
                        self.assertGreaterEqual(setup[0] & 0xFF, 0x20)
                        self.assertLessEqual(setup[0] & 0xFF, 0x60)
                        self.assertEqual(setup[1], 0x6880 | (setup[0] >> 8 & 1))
                    else:
                        self.assertLessEqual(operand, 0x0C)
                if instruction["mnemonic"] == "sach":
                    seen_sach = True
                    self.assertIn((operation >> 8) & 7, {0, 1, 4})
                if instruction["mnemonic"] == "subc":
                    seen_subc = True
                    self.assertEqual(instruction["subc_guard"], ["0x7f80"])
                    self.assertEqual(encoded[-1], NOP)
                if instruction["mnemonic"] == "fifth_pop":
                    seen_fifth_pop = True
                    self.assertEqual(encoded, [POP] * 5)
                    self.assertEqual(instruction["operation_offset"], 4)
        self.assertTrue(seen_sach)
        self.assertTrue(seen_subc)
        self.assertTrue(seen_fifth_pop)

    def test_characterization_rotation_is_explicit_and_non_gating(self) -> None:
        campaign = generate_campaign(3, 12, "characterization")
        kinds = {
            case["body"][0]["characterization"] for case in campaign["cases"]
        }
        self.assertEqual(len(kinds), 12)
        self.assertTrue(all(case["lane"] == "characterization" for case in campaign["cases"]))
        self.assertTrue(
            all(
                not case["constraints"]["documented_encodings_only"]
                for case in campaign["cases"]
            )
        )

    def test_table_templates_use_nonexecuted_program_scratch(self) -> None:
        campaign = generate_campaign(0x7AB1, 500, "defined")
        seen: set[str] = set()
        for case in campaign["cases"]:
            program = words(case)
            for instruction in case["body"]:
                mnemonic = instruction["mnemonic"]
                if mnemonic not in {"tblr", "tblw"}:
                    continue
                seen.add(mnemonic)
                encoded = [int(value, 0) for value in instruction["words"]]
                self.assertEqual(encoded[:2], [LDPK0, 0x6600 | TABLE_ADDRESS_CELL])
                expected = 0x6700 if mnemonic == "tblr" else 0x7D00
                self.assertEqual(encoded[2], expected | TABLE_DATA_CELL)
                self.assertEqual(instruction["operation_offset"], 2)
                self.assertGreater(len(program), TABLE_PROGRAM_ADDRESS)
                self.assertEqual(program[TABLE_PROGRAM_ADDRESS], TABLE_PROGRAM_SEED)
                self.assertEqual(
                    int(case["initial_data"][TABLE_ADDRESS_CELL], 0),
                    TABLE_PROGRAM_ADDRESS,
                )
                self.assertNotEqual(
                    int(case["initial_data"][TABLE_DATA_CELL], 0),
                    TABLE_PROGRAM_SEED,
                )
        self.assertEqual(seen, {"tblr", "tblw"})


class ComparatorTests(unittest.TestCase):
    def test_tampered_manifest_is_rejected_before_comparison(self) -> None:
        manifest = generate_campaign(10, 1, "defined")
        cpp = result("cpp", manifest["cases"])
        hdl = result("hdl", manifest["cases"])
        manifest["cases"][0]["initial_data"][0] = "0xffff"
        with self.assertRaisesRegex(FormatError, "content hash"):
            compare_campaign(manifest, [cpp, hdl])

    def test_fixed_status_bits_and_pop_zero_extension_are_compared(self) -> None:
        manifest = generate_campaign(11, 1, "defined")
        cpp = result("cpp", manifest["cases"])
        hdl = result("hdl", manifest["cases"])
        silicon = result("silicon", manifest["cases"])
        hdl_dump = hdl["cases"][0]["dump"]
        hdl_dump[STATUS_CAPTURE_ADDRESS] = "0x1efe"
        comparison = compare_campaign(manifest, [cpp, hdl, silicon])
        self.assertEqual(comparison["summary"]["defined_failures"], 1)
        self.assertEqual(comparison["cases"][0]["first_mismatch"]["field"], "status")

        hdl_dump[STATUS_CAPTURE_ADDRESS] = "0x0002"
        comparison = compare_campaign(manifest, [cpp, hdl, silicon])
        self.assertEqual(comparison["summary"]["defined_failures"], 0)
        self.assertEqual(comparison["cases"][0]["classification"], "all_equal")

        hdl_dump[STATUS_CAPTURE_ADDRESS] = "0x0000"
        hdl_dump[STACK_DUMP_OFFSET] = "0xf000"
        comparison = compare_campaign(manifest, [cpp, hdl, silicon])
        self.assertEqual(comparison["summary"]["defined_failures"], 1)
        self.assertEqual(comparison["cases"][0]["first_mismatch"]["field"], "stack[0]")

    def test_unanimous_execution_failure_is_not_reported_as_success(self) -> None:
        manifest = generate_campaign(15, 1, "defined")
        cpp = result("cpp", manifest["cases"])
        hdl = result("hdl", manifest["cases"])
        for document in (cpp, hdl):
            document["cases"][0]["status"] = "timeout"
            document["cases"][0].pop("dump")
        comparison = compare_campaign(manifest, [cpp, hdl])
        self.assertEqual(comparison["summary"]["defined_failures"], 1)
        self.assertEqual(comparison["summary"]["execution_failures"], 1)
        self.assertEqual(comparison["cases"][0]["classification"], "all_failed:timeout")

    def test_tri_compare_identifies_outlier_and_first_field(self) -> None:
        manifest = generate_campaign(12, 1, "defined")
        cpp = result("cpp", manifest["cases"])
        hdl = result("hdl", manifest["cases"], delta_index=144)
        silicon = result("silicon", manifest["cases"])
        comparison = compare_campaign(manifest, [cpp, hdl, silicon])
        case = comparison["cases"][0]
        self.assertEqual(case["classification"], "outlier:hdl")
        self.assertEqual(case["first_mismatch"]["field"], "acc_hi")
        self.assertEqual(comparison["summary"]["defined_failures"], 1)

    def test_characterization_difference_never_becomes_defined_failure(self) -> None:
        manifest = generate_campaign(13, 1, "characterization")
        first = result("nmos", manifest["cases"])
        second = result("cmos", manifest["cases"], delta_index=0x20)
        comparison = compare_campaign(manifest, [first, second])
        self.assertEqual(comparison["summary"]["defined_failures"], 0)
        self.assertEqual(comparison["summary"]["characterization_differences"], 1)
        self.assertFalse(comparison["cases"][0]["gating"])

    def test_missing_defined_result_is_reported_as_failure(self) -> None:
        manifest = generate_campaign(14, 2, "defined")
        cpp = result("cpp", manifest["cases"])
        hdl = result("hdl", manifest["cases"])
        hdl["cases"].pop()
        comparison = compare_campaign(manifest, [cpp, hdl])
        self.assertEqual(comparison["summary"]["incomplete"], 1)
        self.assertEqual(comparison["summary"]["defined_failures"], 1)


if __name__ == "__main__":
    unittest.main()
