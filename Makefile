IVERILOG ?= iverilog
VVP ?= vvp
VERILATOR ?= verilator
YOSYS ?= yosys

BUILD_DIR := build
CORE := src/IKA32010.sv
TESTBENCH := tests/IKA32010_h3000_conformance_tb.sv
TEST_VVP := $(BUILD_DIR)/IKA32010_h3000_conformance_tb.vvp

.PHONY: all test lint synth clean

all: test

$(BUILD_DIR):
	mkdir -p $@

$(TEST_VVP): $(CORE) src/IKA32010_mnemonics.sv $(TESTBENCH) | $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -I src -s IKA32010_h3000_conformance_tb -o $@ $(CORE) $(TESTBENCH)

test: $(TEST_VVP)
	$(VVP) $(TEST_VVP)

lint:
	$(VERILATOR) --lint-only --timing -Wall -Wno-fatal -Isrc --top-module IKA32010 $(CORE)

synth:
	$(YOSYS) -q -p 'read_verilog -sv -I src $(CORE); synth_ecp5 -top IKA32010'

clean:
	rm -rf $(BUILD_DIR)
