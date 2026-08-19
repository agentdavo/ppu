// Line-burst requests -> legal AXI4 read bursts.
//
// The scanner asks for a whole line in one request; this chops it into
// chunk = min(beats left, beats to the 4 KB boundary, 256). Seams reach the
// scanner as nothing but gaps in burst_valid, which it tolerates anyway.
// Read-only master: AW/W/B do not exist. One AR outstanding at a time.

module ppu_axi_rd (
    input  wire        clk,          // ACLK == core clock
    input  wire        rst_n,        // ARESETn

    // Scanner side
    input  wire        burst_req,
    input  wire [31:0] burst_addr,
    input  wire [10:0] burst_len,    // 32-bit beats
    output reg         burst_gnt,
    output wire        burst_valid,
    output wire [31:0] burst_data,

    // AXI4 read address channel. ARADDR/ARLEN are combinational views of the
    // chunk state: AXI only requires them stable while ARVALID is high, and
    // cur_addr/left do not move until ARREADY.
    output reg         arvalid,
    output wire [31:0] araddr,
    output wire  [7:0] arlen,        // beats - 1
    output wire  [2:0] arsize,       // 4 bytes
    output wire  [1:0] arburst,      // INCR
    input  wire        arready,

    // AXI4 read data channel
    input  wire        rvalid,
    input  wire [31:0] rdata,
    input  wire        rlast,        // counted, not trusted
    output wire        rready
);

    assign arsize  = 3'b010;
    assign arburst = 2'b01;
    // The scanner consumes a beat every cycle offered; nothing downstream
    // back-pressures, so RREADY is constant high.
    assign rready  = 1'b1;

    localparam S_IDLE = 2'd0, S_AR = 2'd1, S_RUN = 2'd2;
    reg  [1:0]  state;

    reg [31:0] cur_addr;             // start of the NEXT chunk
    reg [10:0] left;                 // beats not yet covered by an issued AR
    reg  [8:0] chunk_left;           // beats outstanding in the current chunk

    // Beats-in-flight == left + chunk_left, so no separate counter is needed:
    // the line is in flight exactly while either is nonzero.
    assign burst_valid = rvalid && ((left != 11'd0) || (chunk_left != 9'd0));
    assign burst_data  = rdata;

    // Largest legal chunk from cur_addr. cur_addr[1:0] is zero (the CSR
    // forces word alignment), so beats to the 4 KB boundary is exact.
    wire [10:0] to4k  = 11'd1024 - {1'b0, cur_addr[11:2]};
    wire [10:0] cap   = (left  < to4k) ? left : to4k;
    wire [10:0] chunk = (cap > 11'd256) ? 11'd256 : cap;

    assign araddr = cur_addr;
    assign arlen  = chunk[7:0] - 8'd1;      // 256 wraps to 8'hFF, correct

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            burst_gnt  <= 1'b0;
            arvalid    <= 1'b0;
            cur_addr   <= 32'd0;
            left       <= 11'd0;
            chunk_left <= 9'd0;
        end else begin
            burst_gnt <= 1'b0;

            case (state)
            S_IDLE: if (burst_req && burst_len != 11'd0) begin
                cur_addr  <= {burst_addr[31:2], 2'b00};
                left      <= burst_len;
                burst_gnt <= 1'b1;
                state     <= S_AR;
            end

            S_AR: begin
                arvalid <= 1'b1;
                if (arvalid && arready) begin
                    arvalid    <= 1'b0;
                    chunk_left <= chunk[8:0];
                    cur_addr   <= cur_addr + {21'd0, chunk[8:0], 2'b00};
                    left       <= left - chunk;
                    state      <= S_RUN;
                end
            end

            S_RUN: if (rvalid) begin
                chunk_left <= chunk_left - 9'd1;
                if (chunk_left == 9'd1)
                    state <= (left != 11'd0) ? S_AR : S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    wire _unused = &{1'b0, rlast, burst_addr[1:0], 1'b0};

endmodule
