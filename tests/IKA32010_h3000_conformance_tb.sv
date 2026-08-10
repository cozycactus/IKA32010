`timescale 1ns/1ps

module IKA32010_h3000_conformance_tb;

reg             clk = 1'b0;
reg             reset_n = 1'b0;
reg             int_n = 1'b1;
wire            men_n;
wire            den_n;
wire            we_n;
wire    [11:0]  address;
reg     [15:0]  data_in = 16'h7F80;
wire    [15:0]  data_out;
wire            data_out_oe;

reg             ram_dmov = 1'b0;
reg             ram_we = 1'b0;
reg     [7:0]   ram_address = 8'h00;
reg     [15:0]  ram_data_in = 16'h0000;
wire    [15:0]  ram_data_out;

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
    .o_DOUT(ram_data_out)
);

task automatic check_condition(input bit condition, input string message);
begin
    if (!condition) begin
        $fatal(1, "FAIL: %s", message);
    end
    checks = checks + 1;
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

    $display("PASS: %0d H3000 conformance checks", checks);
    $finish;
end

endmodule
