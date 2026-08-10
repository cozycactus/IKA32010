IVERILOG ?= iverilog
VVP ?= vvp
VERILATOR ?= verilator
YOSYS ?= yosys
PYTHON ?= python3

BUILD_DIR := build
CORE := src/IKA32010.sv
TESTBENCH := tests/IKA32010_h3000_conformance_tb.sv
TEST_VVP := $(BUILD_DIR)/IKA32010_h3000_conformance_tb.vvp
ORACLE_CAPTURE := src/h3000_tms_oracle_capture.sv
ORACLE_CAPTURE_TESTBENCH := tests/h3000_tms_oracle_capture_tb.sv
ORACLE_CAPTURE_VVP := $(BUILD_DIR)/h3000_tms_oracle_capture_tb.vvp

.PHONY: all test test-python lint synth synth-oracle clean

all: test

$(BUILD_DIR):
	mkdir -p $@

$(TEST_VVP): $(CORE) src/IKA32010_mnemonics.sv $(TESTBENCH) | $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -I src -s IKA32010_h3000_conformance_tb -o $@ $(CORE) $(TESTBENCH)

$(ORACLE_CAPTURE_VVP): $(ORACLE_CAPTURE) $(ORACLE_CAPTURE_TESTBENCH) | $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -s h3000_tms_oracle_capture_tb -o $@ $(ORACLE_CAPTURE) $(ORACLE_CAPTURE_TESTBENCH)

test: $(TEST_VVP) $(ORACLE_CAPTURE_VVP) test-python
	$(VVP) $(TEST_VVP)
	$(VVP) $(ORACLE_CAPTURE_VVP)

test-python:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tests -p 'test_*.py'

lint:
	$(VERILATOR) --lint-only --timing -Wall -Wno-fatal -Isrc --top-module IKA32010 $(CORE)
	$(VERILATOR) --lint-only --timing -Wall -Wno-fatal --top-module h3000_tms_oracle_capture $(ORACLE_CAPTURE)

synth:
	$(YOSYS) -q -p 'read_verilog -sv -I src $(CORE); synth_ecp5 -top IKA32010'

synth-oracle:
	$(YOSYS) -q -p 'read_verilog -sv $(ORACLE_CAPTURE); chparam -set DEPTH 1024 h3000_tms_oracle_capture; synth_ecp5 -top h3000_tms_oracle_capture'

clean:
	rm -rf $(BUILD_DIR)
