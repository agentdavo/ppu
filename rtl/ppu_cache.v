// Direct-mapped fetch cache, one instance per fetch stream.
// One 16-bit word per line: no fill, a miss costs exactly one bus beat.
// Streams must NOT share an instance -- the index and texel streams alternate
// and would evict each other on every access.

module ppu_cache #(
    parameter LINES  = 4,
    parameter AWIDTH = 19,
    parameter IDXW   = 2         // $clog2(LINES)
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                flush,          // on program vector change

    input  wire                req,
    input  wire [AWIDTH-1:0]   addr,           // byte address; bit 0 selects the half
    output wire                hit,
    output wire [15:0]         rdata,

    // Miss path to the bus arbiter
    output wire                miss_req,
    input  wire                miss_ack,
    input  wire [15:0]         miss_data
);

    localparam TAGW = AWIDTH - 1 - IDXW;

    reg [TAGW-1:0] tag  [0:LINES-1];
    reg            vld  [0:LINES-1];
    reg [15:0]     data [0:LINES-1];

    wire [AWIDTH-2:0] line_addr = addr[AWIDTH-1:1];
    wire [IDXW-1:0]   idx       = line_addr[IDXW-1:0];
    wire [TAGW-1:0]   tag_in    = line_addr[AWIDTH-2:IDXW];

    assign hit      = req && vld[idx] && (tag[idx] == tag_in);
    assign rdata    = hit ? data[idx] : miss_data;
    assign miss_req = req && !hit;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < LINES; i = i + 1) begin
                vld[i]  <= 1'b0;
                tag[i]  <= {TAGW{1'b0}};
                data[i] <= 16'd0;
            end
        end else if (flush) begin
            for (i = 0; i < LINES; i = i + 1)
                vld[i] <= 1'b0;
        end else if (miss_req && miss_ack) begin
            tag[idx]  <= tag_in;
            data[idx] <= miss_data;
            vld[idx]  <= 1'b1;
        end
    end

endmodule
