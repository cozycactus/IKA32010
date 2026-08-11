# IKA32010
A BSD-licensed core for TI's TMS32010 DSP © 2024 Sehyeon Kim(Raki)

## Features
* A **semi-cycle-accurate, BSD2 licensed** core.
* FPGA proven.

## Current status
v1.0 – ✅Verified using the arcade games Twin Cobra, Sky Shark, and Wardner by atrac17.

## Module instantiation
The steps below show how to instantiate the IKA32010 module in Verilog:

1. Download this repository or add it as a submodule to your project.
2. You can use the Verilog snippet below to instantiate the module.

```verilog
//Verilog module instantiation example
IKA32010 u_main (
    .i_EMUCLK               (                           ),
    .i_CLKIN_PCEN           (                           ),

    .o_CLKOUT               (                           ),
    .o_CLKOUT_PCEN          (                           ),
    .o_CLKOUT_NCEN          (                           ),

    .i_RS_n                 (                           ),

    .o_MEN_n                (                           ),
    .o_DEN_n                (                           ),
    .o_WE_n                 (                           ),

    .o_AOUT                 (                           ),
    .o_DATA_ADDR            (                           ),
    .i_DIN                  (                           ),
    .o_DOUT                 (                           ),
    .o_DOUT_OE              (                           ),

    .i_BIO_n                (                           ),
    .i_INT_n                (                           )
);
```
3. Attach your signals to the port. The direction and the polarity of the signals are described in the port names. The section below explains what the signals mean.


* `i_EMUCLK` is your system clock.
* `i_CLKIN_PCEN` is the clock enable(positive logic) for positive edge of the CLKIN.
* `o_CLKOUT` is the divided clock from the DSP.
* `i_RS_n` is the synchronous reset.
* `o_DOUT_OE` is the output enable for FPGA's tri-state I/O driver.
* `o_DATA_ADDR` exposes the physical first-generation data-RAM address used by
  the current operand. Logical page-1 addresses `$80-$FF` mirror onto physical
  cells `$80-$8F`; this output is observability only and adds no core state.
* The other signals have the same function as the pins on the original chip.

## Compilation options
* `IKA32010_DISASSEMBLY` You can track the disassembly log to see what opcodes the DSP executed. This requires the `IKA32010_disasm.sv` file.
* `IKA32010_DISASSEMBLY_SHOWID` displays the device ID in a console. This is useful when debugging a system with multiple DSPs or a system with another CPU.
* `IKA32010_DEVICE_ID` and the following string will name the device.

## Open-source validation
* `make test` runs the self-checking H3000 conformance regressions with Icarus Verilog.
* `make lint` elaborates the core with Verilator and reports lint warnings.
* `make synth` synthesizes the core for the ECP5 architecture with Yosys. This checks the core RTL only; a board wrapper and pin constraints are still required for a bitstream.

The focused conformance test also locks TI Rev. B behavior needed by the H3000:
sticky `OV`, the `ABS` minimum-negative/`OVM` corner, unsaturated `SUBC`,
`LAR`/`SAR` self-postmodify ordering, the first-generation multiplier's
`$8000 * $8000 = $C0000000` result, direct-`SST` page-1 selection, indirect
`LST` status/ARP ordering, and interrupt masking, held-low retrigger, and
post-multiply deferral.  These are architectural checks; asynchronous INT pin
phase, original-silicon prefetch timing, and board-level clock limits still
require the physical oracle.

### ROM-free differential campaigns

`tools/tms32010_differential.py` generates deterministic synthetic programs for
comparison between the RTL, a software reference, and real TMS32010 silicon.
The programs contain no Eventide ROM data.  Each one initializes all 144 data
RAM words through `IN PA0`, constructs a reachable state, executes one to eight
constrained instructions, and reports RAM plus register state through a fixed
`OUT` stream.

`TBLR` and `TBLW` are generated as atomic templates against a padded,
non-executed program-memory scratch word at `$300`. This makes the data target,
program target, and stack effect defined. A successful oracle result must
include `body_outputs` and the final unique-address `program_dirty` set; this
prevents a missed `TBLW` write from looking like a matching semantic dump.
The physical-chip harness must run the TMS32010 in microprocessor mode
(`MC/MP=0`) so the complete test image and scratch word use independent
external program memory.

```sh
python3 tools/tms32010_differential.py generate \
  --seed 0x32010 --count 100 --lane defined --output campaign.json
```

Use `--lane characterization` for explicitly non-gating probes such as reserved
SACH shifts, page-one aliases, and reserved branch encodings. A fifth `POP` is
defined by the Rev. B manual and remains in the gating lane. `--lane mixed`
places one characterization case after every three defined cases.  The exact
program, input stream, generator version, and SHA-256 case identity are stored
in the manifest, so a failure remains reproducible if the generator changes.

Oracle adapters return `ika32010-differential-result-1` JSON documents. Compare
two or more (normally C++, RTL, and silicon) with:

```sh
python3 tools/tms32010_differential.py compare \
  --manifest campaign.json \
  --result cpp.json --result rtl.json --result silicon.json \
  --output comparison.json
```

The comparator checks every defined `SST` bit (Rev. B marks only bit 1 as
don't-care) and the complete 16-bit values produced while popping the 12-bit
stack, reports the first
semantic mismatch, and identifies a lone outlier in a three-way run. A shared
timeout or fault is still a defined-lane failure; agreement is not enough when
none of the oracles reaches the dump. Pin-phase and prefetch traces remain a
separate RTL-versus-silicon check because the current software core is
instruction-stepped.

### First-mismatch pin capture

`src/h3000_tms_oracle_capture.sv` is the first hardware-oracle building block.
It snapshots a physical TMS32010 and an independent FPGA shadow at a selected
stable pin phase, compares the control/address/data signatures, and freezes a
96-bit circular trace around the first mismatch. Idle-bus data is retained for
diagnostics but deliberately excluded from the trigger decision.

The record contains both 32-bit pin signatures, a 21-bit caller tag, seven
mismatch categories, and the sampled BIO/INT/RS/shadow-output-enable flags.
Category 6 combines caller-supplied phase alignment faults with a shadow-core
output-direction error (not driving on a write or driving on a read).
Logical BRAM read index zero always addresses the oldest retained record. A
trigger record is kept even with zero post-trigger samples; a post count of one
keeps exactly one following committed snapshot. Run its self-checking test and
standalone ECP5 synthesis with:

```sh
make test
make synth-oracle
```

The reusable module defaults to 1,024 records. The planned H3000 board wrapper
will instantiate 4,096 records: 22 ECP5 EBR blocks for about 223 us of history
at four pin samples per 4.5864 MHz TMS machine cycle. Real and shadow sides must
use separate program-memory responders, so a divergent `TBLW` cannot corrupt a
shared oracle or hide the original mismatch.

## FPGA resource usage
* Altera EP4CE6E22C8: 1243 LEs, 275 registers, BRAM 4096 bits, two 9-bit multiplier elements, fmax=44.98MHz(slow 85C), fmax=103.95MHz(fast 0C)
* Altera 5CSEBA6U23I7(MiSTer): 601 ALMs, 275 registers, BRAM 4096 bits, 1 DSP block, fmax=60.28MHz(slow 100C), fmax=132.33MHz(fast -40C)
