`timescale 1ns/1ps

module h3000_tms_oracle_capture_tb;

localparam integer DEPTH = 8;
localparam integer AW = 3;

reg clk = 1'b0;
reg rst = 1'b1;
reg pin_sample_ce = 1'b0;
reg commit_ce = 1'b0;
reg arm = 1'b0;
reg clear = 1'b0;
reg force_trigger = 1'b0;
reg [AW-1:0] post_samples = 0;
reg [6:0] compare_enable = 7'h7f;

reg [20:0] tag = 0;
reg bio_n = 1'b1;
reg int_n = 1'b1;
reg rs_n = 1'b1;
reg align_fault = 1'b0;

reg real_clkout = 1'b0;
reg real_men_n = 1'b1;
reg real_den_n = 1'b1;
reg real_we_n = 1'b1;
reg [11:0] real_a = 12'd0;
reg [15:0] real_d = 16'd0;

reg shadow_clkout = 1'b0;
reg shadow_men_n = 1'b1;
reg shadow_den_n = 1'b1;
reg shadow_we_n = 1'b1;
reg [11:0] shadow_a = 12'd0;
reg [15:0] shadow_din = 16'd0;
reg [15:0] shadow_dout = 16'd0;
reg shadow_dout_oe = 1'b0;

wire armed;
wire triggered;
wire frozen;
wire [6:0] first_mismatch;
wire [AW-1:0] trigger_addr;
wire [AW-1:0] oldest_addr;
wire [AW:0] valid_count;
wire [31:0] trigger_sample_count;

reg rd_en = 1'b0;
reg [AW-1:0] rd_index = 0;
wire [95:0] rd_data;
wire rd_valid;

integer checks = 0;
integer category;
integer sample_number;
reg [95:0] record;

always #5 clk = ~clk;

h3000_tms_oracle_capture #(
    .DEPTH(DEPTH)
) dut (
    .clk(clk),
    .rst(rst),
    .pin_sample_ce(pin_sample_ce),
    .commit_ce(commit_ce),
    .arm(arm),
    .clear(clear),
    .force_trigger(force_trigger),
    .post_samples(post_samples),
    .compare_enable(compare_enable),
    .tag(tag),
    .bio_n(bio_n),
    .int_n(int_n),
    .rs_n(rs_n),
    .align_fault(align_fault),
    .real_clkout(real_clkout),
    .real_men_n(real_men_n),
    .real_den_n(real_den_n),
    .real_we_n(real_we_n),
    .real_a(real_a),
    .real_d(real_d),
    .shadow_clkout(shadow_clkout),
    .shadow_men_n(shadow_men_n),
    .shadow_den_n(shadow_den_n),
    .shadow_we_n(shadow_we_n),
    .shadow_a(shadow_a),
    .shadow_din(shadow_din),
    .shadow_dout(shadow_dout),
    .shadow_dout_oe(shadow_dout_oe),
    .armed(armed),
    .triggered(triggered),
    .frozen(frozen),
    .first_mismatch(first_mismatch),
    .trigger_addr(trigger_addr),
    .oldest_addr(oldest_addr),
    .valid_count(valid_count),
    .trigger_sample_count(trigger_sample_count),
    .rd_en(rd_en),
    .rd_index(rd_index),
    .rd_data(rd_data),
    .rd_valid(rd_valid)
);

task automatic check(input bit condition, input string message);
begin
    if (!condition)
        $fatal(1, "FAIL: %s", message);
    checks = checks + 1;
end
endtask

task automatic set_matching_idle;
begin
    real_clkout = 1'b0;
    real_men_n = 1'b1;
    real_den_n = 1'b1;
    real_we_n = 1'b1;
    real_a = 12'h123;
    real_d = 16'h4567;
    shadow_clkout = 1'b0;
    shadow_men_n = 1'b1;
    shadow_den_n = 1'b1;
    shadow_we_n = 1'b1;
    shadow_a = 12'h123;
    shadow_din = 16'h4567;
    shadow_dout = 16'h89ab;
    shadow_dout_oe = 1'b0;
    align_fault = 1'b0;
    bio_n = 1'b1;
    int_n = 1'b1;
    rs_n = 1'b1;
end
endtask

task automatic pulse_arm;
begin
    @(negedge clk);
    arm = 1'b1;
    @(posedge clk);
    #1;
    arm = 1'b0;
end
endtask

// Produce one stable snapshot followed by one commit.  force_on_commit is
// asserted only at commit, demonstrating that force_trigger does not need to
// be part of the sampled signature.
task automatic sample_and_commit(
    input [20:0] sample_tag,
    input bit force_on_commit
);
begin
    @(negedge clk);
    tag = sample_tag;
    pin_sample_ce = 1'b1;
    @(posedge clk);
    #1;
    pin_sample_ce = 1'b0;

    @(negedge clk);
    commit_ce = 1'b1;
    force_trigger = force_on_commit;
    @(posedge clk);
    #1;
    commit_ce = 1'b0;
    force_trigger = 1'b0;
end
endtask

task automatic read_record(
    input [AW-1:0] logical_index,
    output [95:0] value
);
begin
    @(negedge clk);
    rd_index = logical_index;
    rd_en = 1'b1;
    @(posedge clk);
    #1;
    rd_en = 1'b0;
    check(rd_valid === 1'b1, "logical read returns rd_valid");
    value = rd_data;
end
endtask

task automatic apply_category_mismatch(input integer which);
begin
    set_matching_idle();
    case (which)
        0: real_clkout = 1'b1;
        1: real_men_n = 1'b0;
        2: real_den_n = 1'b0;
        3: real_we_n = 1'b0;
        4: real_a = 12'h124;
        5: begin
            real_men_n = 1'b0;
            shadow_men_n = 1'b0;
            real_d = 16'h1111;
            shadow_din = 16'h2222;
        end
        6: align_fault = 1'b1;
        default: $fatal(1, "invalid category");
    endcase
end
endtask

initial begin
    repeat (4) @(posedge clk);
    rst = 1'b0;
    set_matching_idle();

    // Circular-buffer wrap: ten commits into DEPTH=8 retain tags 2..9, and
    // logical read index zero maps to the oldest retained physical address.
    pulse_arm();
    check(armed && !triggered && !frozen, "arm enters RUN");
    for (sample_number = 0; sample_number < 10; sample_number = sample_number + 1) begin
        set_matching_idle();
        real_d = sample_number[15:0];
        shadow_din = sample_number[15:0];
        sample_and_commit(sample_number[20:0], 1'b0);
    end
    check(valid_count == 8, "valid_count saturates at DEPTH");
    check(oldest_addr == 2, "oldest physical address advances on wrap");
    for (sample_number = 0; sample_number < 8; sample_number = sample_number + 1) begin
        read_record(sample_number[AW-1:0], record);
        check(record[31:11] == sample_number[20:0] + 21'd2,
              "logical read order survives circular wrap");
        check(record[95:80] == {4'b0111, 12'h123},
              "real signature retains controls and address");
        check(record[79:64] == sample_number[15:0] + 16'd2,
              "real signature retains bus data");
        check(record[63:48] == {4'b0111, 12'h123},
              "shadow signature retains controls and address");
        check(record[47:32] == sample_number[15:0] + 16'd2,
              "shadow signature retains bus data");
        check(record[10:4] == 7'd0, "matching wrapped record has no mismatch");
        check(record[3:0] == 4'b1110, "record retains BIO/INT/RS/OE flags");
    end

    // A data difference while all three bus strobes are idle is diagnostic
    // data only and must neither set category 5 nor trigger the acquisition.
    pulse_arm();
    set_matching_idle();
    real_d = 16'haaaa;
    shadow_din = 16'h5555;
    sample_and_commit(21'h101, 1'b0);
    check(!triggered && armed, "idle data difference is masked");
    read_record(0, record);
    check(record[10:4] == 7'd0, "idle record carries a zero mismatch mask");

    // compare_enable masks both the record and the trigger decision.
    compare_enable = 7'h7d; // disable MEN_n category 1
    real_men_n = 1'b0;
    sample_and_commit(21'h102, 1'b0);
    check(!triggered, "disabled mismatch category cannot trigger");
    read_record(1, record);
    check(record[10:4] == 7'd0, "disabled mismatch category is absent from record");
    compare_enable = 7'h7f;

    // Exercise every mismatch category with post_samples=0.  Each trigger
    // freezes immediately after retaining its trigger record.
    post_samples = 0;
    for (category = 0; category < 7; category = category + 1) begin
        pulse_arm();
        apply_category_mismatch(category);
        sample_and_commit(21'h200 + category[20:0], 1'b0);
        check(triggered && frozen && !armed, "post=0 freezes on trigger record");
        check(first_mismatch == (7'b0000001 << category),
              "first_mismatch identifies the expected category");
        check(trigger_addr == 0, "first record after arm occupies address zero");
        check(trigger_sample_count == 0, "first trigger record has sample index zero");
        check(valid_count == 1, "post=0 retains exactly the trigger record");
        read_record(0, record);
        check(record[31:11] == 21'h200 + category[20:0],
              "trigger record keeps its tag");
        check(record[10:4] == (7'b0000001 << category),
              "trigger record keeps the enabled mismatch category");
    end

    // Category 6 also guards data-bus direction.  A shadow that fails to
    // drive during a write, or drives during a read, must trigger even when
    // the compared data value itself happens to match.
    pulse_arm();
    set_matching_idle();
    real_we_n = 1'b0;
    shadow_we_n = 1'b0;
    real_d = 16'ha55a;
    shadow_dout = 16'ha55a;
    shadow_dout_oe = 1'b0;
    sample_and_commit(21'h280, 1'b0);
    check(triggered && frozen, "missing shadow write OE triggers capture");
    check(first_mismatch == 7'h40, "missing write OE is category 6");

    pulse_arm();
    set_matching_idle();
    real_men_n = 1'b0;
    shadow_men_n = 1'b0;
    shadow_dout_oe = 1'b1;
    sample_and_commit(21'h281, 1'b0);
    check(triggered && frozen, "spurious shadow read OE triggers capture");
    check(first_mismatch == 7'h40, "spurious read OE is category 6");

    // post_samples=1 records exactly one subsequent committed snapshot, and
    // that later mismatch must not replace the first mismatch latch.
    pulse_arm();
    post_samples = 1;
    apply_category_mismatch(4);
    sample_and_commit(21'h301, 1'b0);
    check(triggered && armed && !frozen, "post=1 enters POST after trigger");
    check(first_mismatch == 7'h10, "address mismatch is latched first");
    apply_category_mismatch(0);
    sample_and_commit(21'h302, 1'b0);
    check(frozen && !armed, "one post-trigger commit freezes acquisition");
    check(valid_count == 2, "post=1 retains trigger plus one post record");
    check(first_mismatch == 7'h10, "post mismatch does not replace first mismatch");
    read_record(0, record);
    check(record[31:11] == 21'h301 && record[10:4] == 7'h10,
          "logical record zero is the trigger record");
    read_record(1, record);
    check(record[31:11] == 21'h302 && record[10:4] == 7'h01,
          "logical record one is the sole post-trigger record");

    // A force trigger with matching pins produces a zero first_mismatch and
    // latches the zero-based committed-record count before its increment.
    pulse_arm();
    post_samples = 0;
    set_matching_idle();
    sample_and_commit(21'h401, 1'b0);
    sample_and_commit(21'h402, 1'b0);
    sample_and_commit(21'h403, 1'b1);
    check(triggered && frozen, "force trigger freezes a matching acquisition");
    check(first_mismatch == 0, "force trigger preserves zero mismatch mask");
    check(trigger_sample_count == 2, "trigger sample count uses pre-increment index");
    check(trigger_addr == 2, "force trigger reports its physical record address");
    check(valid_count == 3, "force trigger record is retained");
    read_record(2, record);
    check(record[31:11] == 21'h403 && record[10:4] == 0,
          "force-trigger record is readable and matching");

    // clear returns to IDLE and invalidates metadata without touching memory.
    @(negedge clk);
    clear = 1'b1;
    @(posedge clk);
    #1;
    clear = 1'b0;
    check(!armed && !triggered && !frozen, "clear returns capture to IDLE");
    check(valid_count == 0, "clear invalidates all retained records");

    $display("PASS: %0d oracle capture checks", checks);
    $finish;
end

endmodule
