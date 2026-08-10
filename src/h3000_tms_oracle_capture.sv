`timescale 1ns/1ps

// Small, self-contained capture block for comparing a physical TMS32010 with
// an FPGA shadow core.  pin_sample_ce takes a stable pin snapshot; the next
// commit_ce writes that snapshot to the circular memory.  A commit without a
// pending snapshot is intentionally ignored.
//
// Record layout:
//   [95:64] real signature   {CLKOUT, MEN_n, DEN_n, WE_n, A[11:0], D[15:0]}
//   [63:32] shadow signature {CLKOUT, MEN_n, DEN_n, WE_n, A[11:0], D[15:0]}
//   [31:11] caller-supplied tag
//   [10:4]  enabled mismatch categories
//   [3]     BIO_n
//   [2]     INT_n
//   [1]     RS_n
//   [0]     shadow data-output enable
//
// Mismatch categories:
//   0 CLKOUT, 1 MEN_n, 2 DEN_n, 3 WE_n, 4 address, 5 active-bus data,
//   6 external alignment or shadow output-direction fault.
module h3000_tms_oracle_capture #(
    parameter integer DEPTH = 1024,
    parameter integer AW = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  wire             clk,
    input  wire             rst,

    input  wire             pin_sample_ce,
    input  wire             commit_ce,
    input  wire             arm,
    input  wire             clear,
    input  wire             force_trigger,
    input  wire [AW-1:0]    post_samples,
    input  wire [6:0]       compare_enable,

    input  wire [20:0]      tag,
    input  wire             bio_n,
    input  wire             int_n,
    input  wire             rs_n,
    input  wire             align_fault,

    input  wire             real_clkout,
    input  wire             real_men_n,
    input  wire             real_den_n,
    input  wire             real_we_n,
    input  wire [11:0]      real_a,
    input  wire [15:0]      real_d,

    input  wire             shadow_clkout,
    input  wire             shadow_men_n,
    input  wire             shadow_den_n,
    input  wire             shadow_we_n,
    input  wire [11:0]      shadow_a,
    input  wire [15:0]      shadow_din,
    input  wire [15:0]      shadow_dout,
    input  wire             shadow_dout_oe,

    output wire             armed,
    output reg              triggered,
    output wire             frozen,
    output reg  [6:0]       first_mismatch,
    output reg  [AW-1:0]    trigger_addr,
    output reg  [AW-1:0]    oldest_addr,
    output reg  [AW:0]      valid_count,
    output reg  [31:0]      trigger_sample_count,

    input  wire             rd_en,
    input  wire [AW-1:0]    rd_index,
    output reg  [95:0]      rd_data,
    output reg              rd_valid
);

localparam [1:0] ST_IDLE   = 2'd0;
localparam [1:0] ST_RUN    = 2'd1;
localparam [1:0] ST_POST   = 2'd2;
localparam [1:0] ST_FROZEN = 2'd3;
localparam [AW-1:0] LAST_ADDR = AW'(DEPTH - 1);
localparam [AW:0] DEPTH_COUNT = (AW+1)'(DEPTH);

reg [1:0] state;
reg [95:0] capture_mem [0:DEPTH-1];
reg [AW-1:0] write_addr;
reg [AW-1:0] post_remaining;
reg [31:0] sample_count;

// One-entry snapshot/commit pipeline.  This lets the physical bus be sampled
// at its stable point and committed later without depending on pin movement.
reg pending_snapshot;
reg [31:0] snap_real_signature;
reg [31:0] snap_shadow_signature;
reg [20:0] snap_tag;
reg [6:0]  snap_mismatch;
reg        snap_bio_n;
reg        snap_int_n;
reg        snap_rs_n;
reg        snap_shadow_dout_oe;

wire agreed_program_read = !real_men_n && !shadow_men_n;
wire agreed_io_read      = !real_den_n && !shadow_den_n;
wire agreed_write        = !real_we_n  && !shadow_we_n;
wire compare_data        = agreed_program_read || agreed_io_read || agreed_write;

// On a shadow-core write its output data is the expected physical-bus value;
// at all other times its input data is the corresponding observed/read value.
wire [15:0] shadow_expected_d = agreed_write ? shadow_dout : shadow_din;
wire [15:0] shadow_signature_d = shadow_dout_oe ? shadow_dout : shadow_din;
wire shadow_direction_fault = shadow_dout_oe != !shadow_we_n;

wire [31:0] real_signature = {
    real_clkout, real_men_n, real_den_n, real_we_n, real_a, real_d
};
wire [31:0] shadow_signature = {
    shadow_clkout, shadow_men_n, shadow_den_n, shadow_we_n,
    shadow_a, shadow_signature_d
};

wire [6:0] raw_mismatch = {
    align_fault || shadow_direction_fault,
    compare_data && (real_d != shadow_expected_d),
    real_a      != shadow_a,
    real_we_n   != shadow_we_n,
    real_den_n  != shadow_den_n,
    real_men_n  != shadow_men_n,
    real_clkout != shadow_clkout
};

wire [95:0] pending_record = {
    snap_real_signature,
    snap_shadow_signature,
    snap_tag,
    snap_mismatch,
    snap_bio_n,
    snap_int_n,
    snap_rs_n,
    snap_shadow_dout_oe
};

assign armed  = (state == ST_RUN) || (state == ST_POST);
assign frozen = (state == ST_FROZEN);

function automatic [AW-1:0] increment_addr(input [AW-1:0] address);
begin
    if (address == LAST_ADDR)
        increment_addr = {AW{1'b0}};
    else
        increment_addr = address + {{(AW-1){1'b0}}, 1'b1};
end
endfunction

// rd_index is logical: zero always names the oldest retained record.  Since
// both operands are below DEPTH, their sum needs at most one modulo subtract.
function automatic [AW-1:0] logical_to_physical(
    input [AW-1:0] base,
    input [AW-1:0] index
);
reg [AW:0] sum;
begin
    sum = {1'b0, base} + {1'b0, index};
    if (sum >= DEPTH_COUNT)
        sum = sum - DEPTH_COUNT;
    logical_to_physical = sum[AW-1:0];
end
endfunction

// Synchronous read port, suitable for BRAM inference.  rd_valid is asserted
// for the cycle following a valid rd_en request.
always @(posedge clk) begin
    if (rst || clear || arm) begin
        rd_data  <= 96'd0;
        rd_valid <= 1'b0;
    end else begin
        rd_valid <= 1'b0;
        if (rd_en && ({1'b0, rd_index} < valid_count)) begin
            rd_data  <= capture_mem[logical_to_physical(oldest_addr, rd_index)];
            rd_valid <= 1'b1;
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        state                   <= ST_IDLE;
        write_addr              <= {AW{1'b0}};
        oldest_addr             <= {AW{1'b0}};
        valid_count             <= {(AW+1){1'b0}};
        post_remaining          <= {AW{1'b0}};
        sample_count            <= 32'd0;
        pending_snapshot        <= 1'b0;
        triggered               <= 1'b0;
        first_mismatch          <= 7'd0;
        trigger_addr            <= {AW{1'b0}};
        trigger_sample_count    <= 32'd0;
        snap_real_signature     <= 32'd0;
        snap_shadow_signature   <= 32'd0;
        snap_tag                <= 21'd0;
        snap_mismatch           <= 7'd0;
        snap_bio_n              <= 1'b1;
        snap_int_n              <= 1'b1;
        snap_rs_n               <= 1'b1;
        snap_shadow_dout_oe     <= 1'b0;
    end else if (clear) begin
        // Clear metadata only; clearing every BRAM word would prevent BRAM
        // inference and is unnecessary because valid_count becomes zero.
        state                   <= ST_IDLE;
        write_addr              <= {AW{1'b0}};
        oldest_addr             <= {AW{1'b0}};
        valid_count             <= {(AW+1){1'b0}};
        post_remaining          <= {AW{1'b0}};
        sample_count            <= 32'd0;
        pending_snapshot        <= 1'b0;
        triggered               <= 1'b0;
        first_mismatch          <= 7'd0;
        trigger_addr            <= {AW{1'b0}};
        trigger_sample_count    <= 32'd0;
    end else if (arm) begin
        // Arm starts a new acquisition without touching the BRAM contents.
        state                   <= ST_RUN;
        write_addr              <= {AW{1'b0}};
        oldest_addr             <= {AW{1'b0}};
        valid_count             <= {(AW+1){1'b0}};
        post_remaining          <= {AW{1'b0}};
        sample_count            <= 32'd0;
        pending_snapshot        <= 1'b0;
        triggered               <= 1'b0;
        first_mismatch          <= 7'd0;
        trigger_addr            <= {AW{1'b0}};
        trigger_sample_count    <= 32'd0;
    end else if ((state == ST_RUN) || (state == ST_POST)) begin
        // Capture a fresh pin snapshot.  If a prior snapshot is committed on
        // this same edge, nonblocking assignment semantics commit the old one
        // and leave this new one pending for the next commit_ce.
        if (pin_sample_ce) begin
            snap_real_signature   <= real_signature;
            snap_shadow_signature <= shadow_signature;
            snap_tag              <= tag;
            snap_mismatch         <= raw_mismatch & compare_enable;
            snap_bio_n            <= bio_n;
            snap_int_n            <= int_n;
            snap_rs_n             <= rs_n;
            snap_shadow_dout_oe   <= shadow_dout_oe;
            pending_snapshot      <= 1'b1;
        end

        if (commit_ce && pending_snapshot) begin
            capture_mem[write_addr] <= pending_record;
            write_addr              <= increment_addr(write_addr);
            sample_count            <= sample_count + 32'd1;
            pending_snapshot        <= pin_sample_ce;

            if (valid_count < DEPTH_COUNT)
                valid_count <= valid_count + {{AW{1'b0}}, 1'b1};
            else
                oldest_addr <= increment_addr(oldest_addr);

            if (state == ST_RUN) begin
                if (force_trigger || (snap_mismatch != 7'd0)) begin
                    // sample_count is deliberately latched before increment:
                    // the first committed record after arm has index zero.
                    triggered            <= 1'b1;
                    first_mismatch       <= snap_mismatch;
                    trigger_addr         <= write_addr;
                    trigger_sample_count <= sample_count;

                    if (post_samples == {AW{1'b0}}) begin
                        state            <= ST_FROZEN;
                        pending_snapshot <= 1'b0;
                    end else begin
                        state          <= ST_POST;
                        post_remaining <= post_samples;
                    end
                end
            end else begin
                // Exactly post_samples committed records follow the trigger
                // record.  Later mismatches never replace first_mismatch.
                if (post_remaining == {{(AW-1){1'b0}}, 1'b1}) begin
                    state              <= ST_FROZEN;
                    post_remaining     <= {AW{1'b0}};
                    pending_snapshot   <= 1'b0;
                end else begin
                    post_remaining <= post_remaining - {{(AW-1){1'b0}}, 1'b1};
                end
            end
        end
    end else begin
        // IDLE and FROZEN discard pin activity until the next arm pulse.
        pending_snapshot <= 1'b0;
    end
end

endmodule
