`timescale 1ns/1ps

module IKA32010_h3000_conformance_tb;

reg             clk = 1'b0;
reg             reset_n = 1'b0;
reg             int_n = 1'b1;
wire            men_n;
wire            den_n;
wire            we_n;
wire    [11:0]  address;
wire    [7:0]   data_address;
reg     [15:0]  data_in = 16'h7F80;
wire    [15:0]  data_out;
wire            data_out_oe;

reg             ram_dmov = 1'b0;
reg             ram_we = 1'b0;
reg     [7:0]   ram_address = 8'h00;
reg     [15:0]  ram_data_in = 16'h0000;
wire    [15:0]  ram_data_out;

reg             alu_reset_n = 1'b0;
reg             alu_cen = 1'b0;
reg             alu_ovm = 1'b0;
reg     [3:0]   alu_mode = 4'd4;
reg             alu_paz = 1'b0;
reg             alu_pbz = 1'b0;
reg     [1:0]   alu_pbdata = 2'd0;
reg     [31:0]  alu_pb = 32'h0000_0000;
reg             alu_acc_ld = 1'b0;
reg             alu_v_update = 1'b0;
reg             alu_v_set = 1'b0;
reg             alu_v_rst = 1'b0;
wire    [31:0]  alu_acc;
wire            alu_z;
wire            alu_n;
wire            alu_v;

reg             mul_reset_n = 1'b0;
reg             mul_en = 1'b0;
reg     [15:0]  mul_op0 = 16'h0000;
reg     [15:0]  mul_op1 = 16'h0000;
wire    [31:0]  mul_p;

`ifdef IKA32010_LEGACY_INTERRUPTS
wire core_int_entry_accept = dut.int_rq && dut.if_opcodereg_force_iack &&
    dut.if_pc_modesel == 3'd3;
`else
wire core_int_entry_accept = dut.int_entry_accept;
`endif

integer checks = 0;

always #5 clk = ~clk;

IKA32010 dut (
    .i_EMUCLK(clk),
    .i_CLKIN_PCEN(1'b1),
    .o_CLKOUT(),
    .o_CLKOUT_PCEN(),
    .o_CLKOUT_NCEN(),
    .i_RS_n(reset_n),
    .o_MEN_n(men_n),
    .o_DEN_n(den_n),
    .o_WE_n(we_n),
    .o_AOUT(address),
    .o_DATA_ADDR(data_address),
    .i_DIN(data_in),
    .o_DOUT(data_out),
    .o_DOUT_OE(data_out_oe),
    .i_BIO_n(1'b1),
    .i_INT_n(int_n)
);

IKA32010_ram ram_dut (
    .i_EMUCLK(clk),
    .i_DMOV(ram_dmov),
    .i_WE(ram_we),
    .i_ADDR(ram_address),
    .i_DIN(ram_data_in),
    .o_DOUT(ram_data_out),
    .o_PHYSICAL_ADDR()
);

IKA32010_alu alu_dut (
    .i_EMUCLK(clk),
    .i_CEN(alu_cen),
    .i_RST_n(alu_reset_n),
    .i_ALU_OVM(alu_ovm),
    .i_ALU_MODESEL(alu_mode),
    .i_ALU_PAZ(alu_paz),
    .i_ALU_PBZ(alu_pbz),
    .i_ALU_PBDATA(alu_pbdata),
    .i_ALU_PA(alu_acc),
    .i_ALU_PB(alu_pb),
    .i_ALU_ACC_LD(alu_acc_ld),
    .o_ALU_ACC_OUTPUT(alu_acc),
`ifndef IKA32010_LEGACY_ALU
    .i_ALU_V_UPDATE(alu_v_update),
`endif
    .i_ALU_V_SET(alu_v_set),
    .i_ALU_V_RST(alu_v_rst),
    .o_Z(alu_z),
    .o_N(alu_n),
    .o_V(alu_v)
);

IKA32010_multiplier multiplier_dut (
    .i_EMUCLK(clk),
    .i_RST_n(mul_reset_n),
    .i_MUL_EN(mul_en),
    .i_OP0(mul_op0),
    .i_OP1(mul_op1),
    .o_P(mul_p)
);

task automatic check_condition(input bit condition, input string message);
begin
    if (!condition) begin
        $fatal(1, "FAIL: %s", message);
    end
    checks = checks + 1;
end
endtask

task automatic alu_clock;
begin
    alu_cen = 1'b1;
    @(posedge clk);
    #1;
    alu_cen = 1'b0;
end
endtask

task automatic alu_reset;
begin
    alu_reset_n = 1'b0;
    alu_cen = 1'b1;
    @(posedge clk);
    #1;
    alu_cen = 1'b0;
    alu_reset_n = 1'b1;
    alu_ovm = 1'b0;
    alu_mode = 4'd4;
    alu_paz = 1'b0;
    alu_pbz = 1'b0;
    alu_pbdata = 2'd0;
    alu_pb = 32'h0000_0000;
    alu_acc_ld = 1'b0;
    alu_v_update = 1'b0;
    alu_v_set = 1'b0;
    alu_v_rst = 1'b0;
end
endtask

task automatic multiplier_clock;
begin
    @(posedge clk);
    #1;
end
endtask

task automatic core_negative_edge;
begin
    @(posedge clk);
    while (dut.cyc_ncen !== 1'b1) begin
        @(posedge clk);
    end
    #1;
end
endtask

task automatic ram_write(input [7:0] logical_address, input [15:0] value);
begin
    ram_address = logical_address;
    ram_data_in = value;
    ram_we = 1'b1;
    @(posedge clk);
    #1;
    ram_we = 1'b0;
end
endtask

task automatic ram_read_check(
    input [7:0] logical_address,
    input [15:0] expected,
    input string message
);
begin
    ram_address = logical_address;
    @(posedge clk);
    #1;
    check_condition(ram_data_out === expected, message);
end
endtask

initial begin
    // Let both internal RAM initializers settle, then perform a synchronous reset.
    repeat (8) @(posedge clk);
    #1;
    check_condition(men_n === 1'b1 && den_n === 1'b1 &&
                    we_n === 1'b1 && data_out_oe === 1'b0,
                    "asserted RS leaves every external bus control inactive");
    reset_n = 1'b1;
    repeat (4) @(posedge clk);

    // LDPK 1 must survive deasserted reset and later clocks.
    force dut.ex_state = 1'b1;
    force dut.ex_inst_cycle = 2'd0;
    force dut.if_opcodereg = 16'h6E01;
    core_negative_edge();
    check_condition(dut.reg_dp === 1'b1, "LDPK 1 updates DP with reset deasserted");
    release dut.if_opcodereg;
    repeat (4) @(posedge clk);
    #1;
    check_condition(dut.reg_dp === 1'b1, "DP persists after LDPK 1");

    // MPYK carries a signed 13-bit immediate, including opcode bits 12:8.
    force dut.if_opcodereg = 16'h9FFF;
    force dut.reg_t = 16'h0003;
    #1;
    check_condition(dut.mul_en === 1'b1, "MPYK decode enables the multiplier");
    check_condition(dut.mul_op1 === 16'hFFFF, "MPYK 0x9FFF sign-extends to -1");
    repeat (3) @(posedge clk);
    #1;
    check_condition(dut.reg_p === 32'hFFFFFFFD, "MPYK 3 * -1 produces -3");
    release dut.reg_t;
    release dut.if_opcodereg;

    // At CALL execution PC addresses the operand word; the stack gets PC+1,
    // which is the instruction following the two-word CALL.
    force dut.if_opcodereg = 16'hF800;
    force dut.if_pc = 12'h101;
    force dut.ex_inst_cycle = 2'd0;
    #1;
    check_condition(dut.stk_push === 1'b1, "CALL requests a stack push");
    check_condition(dut.u_stack.i_DIN === 12'h102, "CALL pushes the N+2 return address");
    core_negative_edge();
    check_condition(dut.u_stack.stack[0] === 12'h102, "CALL commits the N+2 return address");
    release dut.if_pc;
    release dut.if_opcodereg;

    // TBLW cycle 2 fetches the next opcode but must not copy that discarded
    // program word into its source data-memory location.
    force dut.reg_dp = 1'b0;
    dut.u_ram.RAM[1] = 16'hBEEF;
    force dut.if_opcodereg = 16'h7D01;
    force dut.ex_inst_cycle = 2'd2;
    force dut.busctrl_inlatch = 16'hCAFE;
    #1;
    check_condition(dut.ram_wr === 1'b0, "TBLW final cycle does not assert data RAM write");
    @(posedge clk);
    #1;
    check_condition(dut.u_ram.RAM[1] === 16'hBEEF, "TBLW preserves its source data word");
    release dut.busctrl_inlatch;
    release dut.if_opcodereg;
    release dut.reg_dp;
    release dut.ex_inst_cycle;
    release dut.ex_state;

    // Page 1 has only 16 physical words: all logical $80-$FF addresses alias
    // by their low nibble, while page 0 remains independent.
    ram_write(8'h0F, 16'h1111);
    ram_write(8'h8F, 16'h2222);
    ram_read_check(8'h0F, 16'h1111, "page 0 remains distinct from page 1");
    ram_read_check(8'hFF, 16'h2222, "$FF aliases the physical $8F cell");
    ram_write(8'h9F, 16'h3333);
    ram_read_check(8'h8F, 16'h3333, "$9F and $8F share one physical cell");

    // The top-level provenance pin exposes that same physical address.  It
    // lets an H3000 bus wrapper prove that simultaneous PEL OUT operations
    // came from the same C10 cell without exposing the RAM contents.
    force dut.reg_dp = 1'b1;
    force dut.if_opcodereg = 16'h007F;
    #1;
    check_condition(data_address === 8'h8F,
                    "top-level data address maps direct $FF to physical $8F");
    force dut.if_opcodereg = 16'h0080;
    force dut.ar_addr_output = 8'h9A;
    #1;
    check_condition(data_address === 8'h8A,
                    "top-level data address maps indirect $9A to physical $8A");
    release dut.ar_addr_output;
    release dut.if_opcodereg;
    release dut.reg_dp;

    // DMOV increments the logical address first. $8F + 1 is logical $90,
    // which aliases physical $80.
    ram_write(8'h8F, 16'hBEEF);
    ram_address = 8'h8F;
    @(posedge clk);
    #1;
    ram_dmov = 1'b1;
    @(posedge clk);
    #1;
    ram_dmov = 1'b0;
    ram_read_check(8'h80, 16'hBEEF, "DMOV $8F destination aliases physical $80");

    // OV is sticky across later non-overflowing arithmetic.  Only an explicit
    // flag restore/clear operation may reset it.
    alu_reset();
    alu_dut.o_ALU_ACC_OUTPUT = 32'h7FFF_FFFF;
    alu_mode = 4'd4; // ADD
    alu_pb = 32'h0000_0001;
    alu_acc_ld = 1'b1;
    alu_v_update = 1'b1;
    alu_clock();
    check_condition(alu_acc === 32'h8000_0000, "ADD wraps when OVM is clear");
    check_condition(alu_v === 1'b1, "overflowing ADD sets OV");
    alu_pb = 32'h0000_0000;
    alu_clock();
    check_condition(alu_v === 1'b1, "non-overflowing ADD leaves sticky OV set");
    alu_acc_ld = 1'b0;
    alu_v_update = 1'b0;
    alu_v_rst = 1'b1;
    alu_clock();
    alu_v_rst = 1'b0;
    check_condition(alu_v === 1'b0, "explicit status restore can clear OV");

    // ABS has a TI-defined minimum-negative corner selected by OVM.
    alu_dut.o_ALU_ACC_OUTPUT = 32'h8000_0000;
    alu_mode = 4'd3; // ABS
    alu_pbz = 1'b1;
    alu_acc_ld = 1'b1;
    alu_v_update = 1'b1;
    alu_ovm = 1'b0;
    alu_clock();
    check_condition(alu_acc === 32'h8000_0000,
        "ABS min-negative wraps with OVM clear");
    check_condition(alu_v === 1'b1, "ABS min-negative sets sticky OV");

    alu_dut.o_ALU_ACC_OUTPUT = 32'h8000_0000;
    alu_dut.o_V = 1'b0;
    alu_ovm = 1'b1;
    alu_clock();
    check_condition(alu_acc === 32'h7FFF_FFFF,
        "ABS min-negative saturates positive with OVM set");
    check_condition(alu_v === 1'b1,
        "saturated ABS min-negative still sets OV");

    // SUBC reports its subtraction overflow but TI explicitly says OVM must
    // not saturate the intermediate candidate.
    alu_reset();
    alu_dut.o_ALU_ACC_OUTPUT = 32'h7FFF_FFFF;
    alu_mode = 4'd6; // SUBC
    alu_pb = 32'hFFFF_8000;
    alu_ovm = 1'b1;
    alu_acc_ld = 1'b0;
    alu_v_update = 1'b1;
    alu_clock();
    alu_mode = 4'd4;
    alu_pb = 32'h0000_0000;
    alu_v_update = 1'b0;
    alu_clock();
    check_condition(alu_acc === 32'hFFFF_FFFE,
        "SUBC ignores OVM saturation when its subtraction overflows");
    check_condition(alu_v === 1'b1,
        "SUBC subtraction overflow is retained in sticky OV");

    // First-generation TMS32010 multiplier special case.
    mul_reset_n = 1'b0;
    multiplier_clock();
    mul_reset_n = 1'b1;
    mul_en = 1'b1;
    mul_op0 = 16'h8000;
    mul_op1 = 16'h8000;
    multiplier_clock();
    multiplier_clock();
    check_condition(mul_p === 32'hC000_0000,
        "$8000 * $8000 uses the TMS32010 special product");
    mul_op0 = 16'hFFFF;
    mul_op1 = 16'h0002;
    multiplier_clock();
    multiplier_clock();
    check_condition(mul_p === 32'hFFFF_FFFE,
        "ordinary signed 16x16 multiply remains unchanged");
    mul_en = 1'b0;

    // LAR reads through the old current AR.  A self-target suppresses its
    // postmodify, while loading the other AR still modifies the address AR.
    force dut.ex_state = 1'b1;
    force dut.ex_inst_cycle = 2'd0;
    dut.reg_arp = 1'b0;
    dut.reg_ar[0] = 16'h0005;
    dut.reg_ar[1] = 16'h0000;
    dut.u_ram.RAM[5] = 16'h1234;
    force dut.if_opcodereg = 16'h39A8; // LAR AR1,*+ (no ARP replacement)
    core_negative_edge();
    check_condition(dut.reg_ar[0] === 16'h0006,
        "LAR other-target postincrements the old current AR");
    check_condition(dut.reg_ar[1] === 16'h1234,
        "LAR other-target loads the selected auxiliary register");

    dut.reg_arp = 1'b0;
    dut.reg_ar[0] = 16'h0005;
    dut.u_ram.RAM[5] = 16'hBEEF;
    force dut.if_opcodereg = 16'h38A8; // LAR AR0,*+
    core_negative_edge();
    check_condition(dut.reg_ar[0] === 16'hBEEF,
        "LAR self-target suppresses postincrement of the loaded value");

    // SAR of the current AR with auto-update stores the updated value at the
    // address selected by the old AR.
    dut.reg_arp = 1'b0;
    dut.reg_ar[0] = 16'h0005;
    dut.u_ram.RAM[5] = 16'h0000;
    force dut.if_opcodereg = 16'h30A8; // SAR AR0,*+
    core_negative_edge();
    check_condition(dut.reg_ar[0] === 16'h0006,
        "SAR self-target postincrements the current AR");
    check_condition(dut.u_ram.RAM[5] === 16'h0006,
        "SAR self-target stores the postincremented AR at the old address");

    // Direct SST always forces page 1, independently of DP.  On the 16-word
    // TMS32010 page this reached $7D encoding aliases physical $8D.
    dut.reg_dp = 1'b0;
    dut.u_ram.RAM[8'h7D] = 16'h1111;
    dut.u_ram.RAM[8'h8D] = 16'h2222;
    force dut.if_opcodereg = 16'h7C7D;
    core_negative_edge();
    check_condition(dut.u_ram.RAM[8'h7D] === 16'h1111,
        "direct SST does not write the DP-selected page 0 cell");
    check_condition(dut.u_ram.RAM[8'h8D] === dut.flag_output,
        "direct SST forces its write to page 1");

    // For indirect LST the old ARP selects and postmodifies the address AR;
    // ARP itself comes from the restored word and ignores encoded next ARP.
    dut.reg_arp = 1'b0;
    dut.reg_ar[0] = 16'h0005;
    dut.u_ram.RAM[5] = 16'hC001; // OV=1, OVM=1, saved ARP=0, DP=1
    force dut.if_opcodereg = 16'h7BA1; // LST *+,1
    core_negative_edge();
    check_condition(dut.reg_ar[0] === 16'h0006,
        "indirect LST postmodifies the old current AR");
    check_condition(dut.reg_arp === 1'b0,
        "indirect LST restores ARP from status and ignores encoded next ARP");
    check_condition(dut.reg_ovm === 1'b1 && dut.reg_dp === 1'b1 &&
                    dut.alu_flag_ovfl === 1'b1,
        "indirect LST restores OV/OVM/DP from the old addressed word");

    dut.reg_intm = 1'b0;
    dut.reg_arp = 1'b0;
    dut.reg_ar[0] = 16'h0006;
    dut.u_ram.RAM[6] = 16'hE100; // saved INTM=1 and ARP=1
    force dut.if_opcodereg = 16'h7B88; // LST *, no encoded next ARP
    core_negative_edge();
    check_condition(dut.reg_arp === 1'b1,
        "indirect LST restores a set ARP bit from status without next ARP");
    check_condition(dut.reg_intm === 1'b0,
        "LST preserves live INTM even when the saved status bit differs");

    // Interrupt entry masks interrupts, held-low INT becomes pending again
    // after acknowledge, and MPY/MPYK protect the following instruction.
    dut.reg_intm = 1'b0;
    dut.if_pc = 12'h345;
    force dut.int_latched = 1'b1;
    force dut.if_opcodereg = 16'h7F80; // NOP
    #1;
    check_condition(core_int_entry_accept === 1'b1,
        "eligible pending INT is accepted at an instruction boundary");
    core_negative_edge();
    check_condition(dut.reg_intm === 1'b1,
        "accepted interrupt entry sets INTM");
    release dut.int_latched;

    dut.reg_intm = 1'b1;
    dut.int_latched = 1'b1;
    force dut.int_n_zz = 1'b0;
    force dut.if_opcodereg = 16'hF000; // internal IACK
    core_negative_edge();
    check_condition(dut.int_latched === 1'b0,
        "interrupt acknowledge clears the pending latch once");
    force dut.if_opcodereg = 16'h7F80;
    core_negative_edge();
    check_condition(dut.int_latched === 1'b1,
        "held-low synchronized INT reasserts pending state after acknowledge");
    release dut.int_n_zz;

    // EINT has the same documented one-following-instruction acceptance
    // boundary when it changes a previously masked state.  No extra shadow
    // register is needed in this pipelined core: INTM is still set while EINT
    // executes, then the following instruction executes while entry is
    // accepted at its completion.
    dut.reg_intm = 1'b1;
    force dut.int_latched = 1'b1;
    force dut.if_opcodereg = 16'h7F82; // EINT
    #1;
    check_condition(core_int_entry_accept === 1'b0,
        "pending INT is not accepted during masked EINT");
    core_negative_edge();
    check_condition(dut.reg_intm === 1'b0,
        "EINT enables interrupts before its protected follower");
    force dut.if_opcodereg = 16'h7F80; // following NOP
    #1;
    check_condition(core_int_entry_accept === 1'b1,
        "pending INT is accepted only as the instruction following EINT completes");
    core_negative_edge();
    check_condition(dut.reg_intm === 1'b1,
        "post-EINT interrupt entry masks further interrupts");

    dut.reg_intm = 1'b0;
    force dut.if_opcodereg = 16'h6D00; // MPY direct
    #1;
    check_condition(core_int_entry_accept === 1'b0 &&
                    dut.if_opcodereg_force_iack === 1'b0,
        "MPY defers pending interrupt acceptance");
    force dut.if_opcodereg = 16'h7F80; // protected following instruction
    #1;
    check_condition(core_int_entry_accept === 1'b1,
        "pending INT is accepted only after the instruction following MPY executes");
    force dut.if_opcodereg = 16'h8000; // MPYK 0
    #1;
    check_condition(core_int_entry_accept === 1'b0,
        "MPYK defers pending interrupt acceptance");
    force dut.if_opcodereg = 16'h7F80;
    #1;
    check_condition(core_int_entry_accept === 1'b1,
        "pending INT is accepted after the instruction following MPYK");
    release dut.int_latched;
    release dut.if_opcodereg;
    release dut.ex_inst_cycle;
    release dut.ex_state;

    $display("PASS: %0d H3000 conformance checks", checks);
    $finish;
end

endmodule
