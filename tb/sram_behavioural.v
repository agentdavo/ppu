// Behavioural stand-in for gf180mcu_fd_ip_sram__sram256x8m8wm1, for RTL
// functional simulation only.
//
// WHY NOT USE THE FOUNDRY MODEL HERE
// ---------------------------------
// The foundry Verilog model samples its control inputs inside
// `always @(posedge clk_dly)`, where `clk_dly` is CLK delayed by
// `Tdly = 100 ps`. It therefore requires its inputs to remain stable for 100 ps
// AFTER each clock edge. A zero-delay RTL simulation drives them straight from
// non-blocking register updates, so by the time the model looks, the inputs
// already carry the NEXT cycle's values -- a read issued in cycle N is seen as
// the write from cycle N+1, and Q returns the wrong word. The bench caught this
// as "blend applied N times to word N".
//
// That is a simulation race, not an RTL defect: real flops have non-zero
// clock-to-Q, and gate-level simulation supplies it. So the foundry model stays
// in the GL flow, where it belongs, and RTL functional checks run against this.
//
// Also worth knowing: the foundry model hard-codes `Tcyc = 55600` ps -- a 55.6 ns
// minimum period, i.e. 18 MHz -- while the liberty for the same macro reports
// min_period 6.118 ns at tt_025C_5v00. 55.6 ns is close to the liberty's
// ss_125C_1v62 figure of 53.62 ns, so the model appears pinned to the 1.8 V
// worst-case corner regardless of the rail being simulated. Do not read the
// Verilog model's timing as authoritative for a 5 V design.
//
// Semantics implemented here, matching the datasheet and the liberty:
//   - all enables active LOW (CEN, GWEN, WEN)
//   - synchronous, single port, one access per cycle
//   - registered read: address at edge N, data valid throughout cycle N+1
//   - a write does NOT update Q (no write-through)
//   - WEN is per-BIT, not per-byte

`timescale 1ns/1ps

module gf180mcu_fd_ip_sram__sram256x8m8wm1 (
    input  wire       CLK,
    input  wire       CEN,     // chip enable, active low
    input  wire       GWEN,    // global write enable, active low
    input  wire [7:0] WEN,     // per-bit write enable, active low
    input  wire [7:0] A,
    input  wire [7:0] D,
    output reg  [7:0] Q
);

    reg [7:0] mem [0:255];

    integer i;
    initial begin
        for (i = 0; i < 256; i = i + 1) mem[i] = 8'd0;
        Q = 8'd0;
    end

    always @(posedge CLK) begin
        if (!CEN) begin
            if (!GWEN) begin
                // Bit-level masking: a 0 in WEN[b] writes bit b.
                mem[A] <= (mem[A] & WEN) | (D & ~WEN);
            end else begin
                Q <= mem[A];
            end
        end
    end

endmodule


module gf180mcu_fd_ip_sram__sram512x8m8wm1 (
    input  wire       CLK,
    input  wire       CEN,     // chip enable, active low
    input  wire       GWEN,    // global write enable, active low
    input  wire [7:0] WEN,     // per-bit write enable, active low
    input  wire [8:0] A,
    input  wire [7:0] D,
    output reg  [7:0] Q
);

    reg [7:0] mem [0:511];

    integer i;
    initial begin
        for (i = 0; i < 512; i = i + 1) mem[i] = 8'd0;
        Q = 8'd0;
    end

    always @(posedge CLK) begin
        if (!CEN) begin
            if (!GWEN) begin
                // Bit-level masking: a 0 in WEN[b] writes bit b.
                mem[A] <= (mem[A] & WEN) | (D & ~WEN);
            end else begin
                Q <= mem[A];
            end
        end
    end

endmodule
