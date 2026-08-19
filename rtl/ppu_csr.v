// ppu_csr -- APB3 register file: control/status, IRQs, palette port, host
// memory keyhole, framebuffer and CRTC configuration. Zero-wait except PRAM
// reads (one wait state) and MEM_DATA accesses (stall until arbiter ack).
//
// PRAM is a single-port macro shared with the per-pixel lookup, so every CSR
// access steals one cycle from it.

`include "ppu_defs.vh"

module ppu_csr (
    input  wire        clk,
    input  wire        rst_n,

    // APB slave
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire  [7:0] paddr,
    input  wire [31:0] pwdata,
    output reg  [31:0] prdata,
    output wire        pready,

    // Control out
    output wire        ppu_enable,
    output reg         pc_load,
    output reg  [18:0] pc_out,
    output wire        halt_hsync,
    output wire        halt_vsync,

    // Display configuration
    output wire        cfg_dig_en,
    output wire        cfg_hsync_pol,
    output wire        cfg_vsync_pol,

    // Linear framebuffer engine: width, height, stride, format all readable
    // back from hardware (simple-framebuffer contract).
    output wire        fb_en,
    output wire  [2:0] fb_fmt,
    output reg  [31:0] fb_base,
    output reg  [15:0] fb_stride,
    output reg   [9:0] fb_w,
    output reg   [9:0] fb_h,

    // Programmable CRTC: bare compare points, firmware-computed; reset is
    // 640x480@60.
    output reg  [10:0] crt_h_last, crt_h_act, crt_h_bnd, crt_hs_s, crt_hs_e,
    output reg   [9:0] crt_v_last, crt_v_act, crt_vs_s, crt_vs_e,
    output reg   [9:0] crt_prep, crt_line_lim,
    output reg         crt_dblx, crt_dbly,
    output reg  [10:0] crt_int_w,      // internal line width in pixels

    // Palette port
    output reg         pram_we,
    output reg         pram_re,
    output reg   [7:0] pram_addr,
    output reg  [15:0] pram_wdata,
    input  wire [15:0] pram_rdata,

    // Bring-up keyhole into external memory: set MEM_ADDR once, then stream
    // MEM_DATA; the address auto-increments by 2 per access.
    output reg  [18:0] mem_addr,
    output reg  [15:0] mem_wdata,
    output reg         mem_wreq,
    input  wire        mem_wack,
    input  wire [15:0] mem_rdata_in,
    output reg         mem_rreq,

    // Render-fetch instrumentation: stall cycles and answered beats.
    input  wire        bus_stall_i,
    input  wire        bus_fetch_i,

    // Status in
    input  wire        halted,
    input  wire        underrun,
    output reg         underrun_clr,
    input  wire        busy,
    input  wire  [8:0] render_y,
    input  wire        vblank,
    input  wire        frame_tick,     // pulse when the frame restarts and
                                       // fb_base is latched by the scanner

    output wire        irq
);

    localparam A_CTRL   = 8'h00, A_STATUS = 8'h04, A_PC     = 8'h08,
               A_IRQ_EN = 8'h0C, A_IRQ_ST = 8'h10, A_DISP   = 8'h14,
               A_PRAM_A = 8'h18, A_PRAM_D = 8'h1C, A_BUSST  = 8'h20,
               A_MEM_A  = 8'h24, A_MEM_D  = 8'h28,
               A_FB_CTL = 8'h2C, A_FB_BAS = 8'h30, A_FB_STR = 8'h34,
               A_FB_SIZ = 8'h38,
               A_CRT_H1 = 8'h3C, A_CRT_H2 = 8'h40, A_CRT_H3 = 8'h44,
               A_CRT_V1 = 8'h48, A_CRT_V2 = 8'h4C, A_CRT_LN = 8'h50,
               A_CRT_MD = 8'h54, A_FRAME  = 8'h58;

    reg  [3:0] ctrl;        // enable, soft_rst, halt_hsync, halt_vsync
    reg  [3:0] disp_cfg;    // dig_en, reserved, hsync_pol, vsync_pol -- bit 1
                            // is stored and reads back but drives nothing
                            // (register-map compat)
    reg  [3:0] irq_en;      // underrun, vblank, halt, reserved
    reg  [3:0] irq_sts;
    reg  [3:0] fb_ctrl;     // fb_en, fmt[2:0]

    assign fb_en         = fb_ctrl[0];
    assign fb_fmt        = fb_ctrl[3:1];
    assign ppu_enable    = ctrl[0];
    assign halt_hsync    = ctrl[2];
    assign halt_vsync    = ctrl[3];
    assign cfg_dig_en    = disp_cfg[0];
    assign cfg_hsync_pol = disp_cfg[2];
    assign cfg_vsync_pol = disp_cfg[3];
    assign irq           = |(irq_sts & irq_en);

    // A PRAM read needs one wait state for the macro's registered Q.
    wire   access    = psel && penable;
    wire   pram_read = psel && !pwrite && (paddr == A_PRAM_D);
    reg    pram_wait;

    // MEM_D arbitrates against the render fetch; PREADY holds low until the
    // arbiter acks. Reads and writes must both raise a request. `mem_done`
    // is per-transfer, not per-cycle: a stalled transfer holds psel/penable
    // for many edges, and without the flag one write would land twice.
    wire   mem_read  = psel && !pwrite && (paddr == A_MEM_D);
    wire   mem_write = psel &&  pwrite && (paddr == A_MEM_D);
    reg    mem_done;
    assign pready    = !(pram_read && !pram_wait)
                    && !((mem_read || mem_write) && !mem_done);

    reg [15:0] mem_rdata_q;
    reg [15:0] bus_stall_q, bus_fetch_q;
    reg vblank_d, underrun_d, halted_d;

    // Frame counter and flip-pending flag, for OS vblank accounting and
    // flip-done events: flip_pend sets on an FB_BASE write and clears on the
    // frame_tick that latches the new base. A write coincident with the tick
    // wins -- that base was not latched this frame.
    reg [15:0] frame_cnt;
    reg        flip_pend;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl         <= 4'b0000;
            // Both paths on; both syncs active-low (640x480@60 VESA DMT
            // polarity).
            disp_cfg     <= 4'b0011;
            irq_en       <= 4'b0000;
            irq_sts      <= 4'b0000;
            pc_load      <= 1'b0;
            pc_out       <= 19'd0;
            pram_we      <= 1'b0;
            pram_re      <= 1'b0;
            pram_addr    <= 8'd0;
            pram_wdata   <= 16'd0;
            underrun_clr <= 1'b0;
            pram_wait    <= 1'b0;
            vblank_d     <= 1'b0;
            underrun_d   <= 1'b0;
            halted_d     <= 1'b0;
            mem_addr     <= 19'd0;
            mem_wdata    <= 16'd0;
            mem_wreq     <= 1'b0;
            mem_rreq     <= 1'b0;
            mem_rdata_q  <= 16'd0;
            mem_done     <= 1'b0;
            bus_stall_q  <= 16'd0;
            bus_fetch_q  <= 16'd0;
            frame_cnt    <= 16'd0;
            flip_pend    <= 1'b0;
            // Framebuffer engine resets OFF; geometry resets to 320x240,
            // 640-byte stride, a1r5g5b5.
            fb_ctrl      <= 4'b0000;
            fb_base      <= 32'd0;
            fb_stride    <= `PPU_FB_RST_STRIDE;
            fb_w         <= `PPU_FB_RST_W;
            fb_h         <= `PPU_FB_RST_H;
            // 640x480@60 VESA DMT timing.
            crt_h_last   <= 11'd799;  crt_h_act <= 11'd640; crt_h_bnd <= 11'd639;
            crt_hs_s     <= 11'd656;  crt_hs_e  <= 11'd752;
            crt_v_last   <= 10'd524;  crt_v_act <= 10'd480;
            crt_vs_s     <= 10'd490;  crt_vs_e  <= 10'd492;
            crt_prep     <= 10'd477;  crt_line_lim <= 10'd477;
            crt_dblx     <= 1'b1;     crt_dbly  <= 1'b1;
            crt_int_w    <= 11'd320;
        end else begin
            pc_load      <= 1'b0;
            pram_we      <= 1'b0;
            pram_re      <= 1'b0;
            underrun_clr <= 1'b0;
            ctrl[1]      <= 1'b0;       // soft reset is self-clearing

            // One request per transfer, held until the arbiter grants.
            // Clear on the SETUP phase (penable low): psel can drop and
            // re-raise between edges on back-to-back transfers, so !psel is
            // not a reliable clear.
            if (!penable)
                mem_done <= 1'b0;
            else if (mem_wack)
                mem_done <= 1'b1;

            if (mem_read && !mem_rreq && !mem_done)
                mem_rreq <= 1'b1;

            // On ack: drop the request, capture read data, step the address.
            if (mem_wack) begin
                if (mem_rreq) mem_rdata_q <= mem_rdata_in;
                mem_wreq <= 1'b0;
                mem_rreq <= 1'b0;
                mem_addr <= mem_addr + 19'd2;
            end

            // Any write to BUS_STAT zeroes both counters; they saturate at
            // 0xFFFF.
            if (access && pwrite && paddr == A_BUSST) begin
                bus_stall_q <= 16'd0;
                bus_fetch_q <= 16'd0;
            end else begin
                if (bus_stall_i && bus_stall_q != 16'hFFFF)
                    bus_stall_q <= bus_stall_q + 16'd1;
                if (bus_fetch_i && bus_fetch_q != 16'hFFFF)
                    bus_fetch_q <= bus_fetch_q + 16'd1;
            end

            if (frame_tick)
                frame_cnt <= frame_cnt + 16'd1;
            if (access && pwrite && paddr == A_FB_BAS)
                flip_pend <= 1'b1;
            else if (frame_tick)
                flip_pend <= 1'b0;

            // IRQ sources latch on the rising edge, not the level, so W1C
            // works while the source is still asserted.
            vblank_d   <= vblank;
            underrun_d <= underrun;
            halted_d   <= halted;
            if (underrun && !underrun_d) irq_sts[0] <= 1'b1;
            if (vblank   && !vblank_d)   irq_sts[1] <= 1'b1;
            if (halted   && !halted_d)   irq_sts[2] <= 1'b1;

            // One wait state on a PRAM read: issue, then capture.
            if (pram_read && !pram_wait) begin
                pram_re   <= 1'b1;
                pram_wait <= 1'b1;
            end else if (pram_wait) begin
                pram_wait <= 1'b0;
            end

            if (access && pwrite) begin
                case (paddr)
                    A_CTRL:   ctrl     <= pwdata[3:0];
                    A_PC:     begin pc_out <= pwdata[18:0]; pc_load <= 1'b1; end
                    A_IRQ_EN: irq_en   <= pwdata[3:0];
                    A_IRQ_ST: begin
                                  irq_sts <= irq_sts & ~pwdata[3:0];   // W1C
                                  if (pwdata[0]) underrun_clr <= 1'b1;
                              end
                    A_DISP:   disp_cfg <= pwdata[3:0];
                    A_PRAM_A: pram_addr <= pwdata[7:0];
                    A_PRAM_D: begin pram_wdata <= pwdata[15:0]; pram_we <= 1'b1; end
                    A_MEM_A:  mem_addr <= pwdata[18:0];
                    A_MEM_D:  if (!mem_wreq && !mem_done) begin
                                  mem_wdata <= pwdata[15:0];
                                  mem_wreq  <= 1'b1;
                              end
                    A_FB_CTL: fb_ctrl   <= pwdata[3:0];
                    // FB_BASE/FB_STRIDE bits 1:0 forced to zero: one burst
                    // beat is one 32-bit scanbuf word. FB_BASE is the full
                    // 32-bit system physical address.
                    A_FB_BAS: fb_base   <= {pwdata[31:2], 2'b00};
                    A_FB_STR: fb_stride <= {pwdata[15:2], 2'b00};
                    A_FB_SIZ: begin fb_w <= pwdata[9:0]; fb_h <= pwdata[25:16]; end
                    A_CRT_H1: begin crt_h_last <= pwdata[10:0]; crt_h_act <= pwdata[26:16]; end
                    A_CRT_H2: begin crt_hs_s   <= pwdata[10:0]; crt_hs_e  <= pwdata[26:16]; end
                    A_CRT_H3: begin crt_h_bnd  <= pwdata[10:0]; end
                    A_CRT_V1: begin crt_v_last <= pwdata[9:0];  crt_v_act <= pwdata[25:16]; end
                    A_CRT_V2: begin crt_vs_s   <= pwdata[9:0];  crt_vs_e  <= pwdata[25:16]; end
                    A_CRT_LN: begin crt_prep   <= pwdata[9:0];  crt_line_lim <= pwdata[25:16]; end
                    A_CRT_MD: begin crt_dblx <= pwdata[0]; crt_dbly <= pwdata[1];
                                    crt_int_w <= pwdata[26:16]; end
                    default:  ;
                endcase
            end
        end
    end

    always @* begin
        case (paddr)
            A_CTRL:   prdata = {28'd0, ctrl};
            A_STATUS: prdata = {14'd0, render_y, 5'd0, fb_en, busy, underrun, halted};
            A_PC:     prdata = {13'd0, pc_out};
            A_IRQ_EN: prdata = {28'd0, irq_en};
            A_IRQ_ST: prdata = {28'd0, irq_sts};
            A_DISP:   prdata = {28'd0, disp_cfg};
            A_PRAM_A: prdata = {24'd0, pram_addr};
            A_PRAM_D: prdata = {16'd0, pram_rdata};
            A_BUSST:  prdata = {bus_stall_q, bus_fetch_q};
            A_MEM_A:  prdata = {13'd0, mem_addr};
            A_MEM_D:  prdata = {16'd0, mem_rdata_q};
            A_FB_CTL: prdata = {28'd0, fb_ctrl};
            A_FB_BAS: prdata = fb_base;
            A_FB_STR: prdata = {16'd0, fb_stride};
            A_FB_SIZ: prdata = {6'd0, fb_h, 6'd0, fb_w};
            A_CRT_H1: prdata = {5'd0, crt_h_act, 5'd0, crt_h_last};
            A_CRT_H2: prdata = {5'd0, crt_hs_e, 5'd0, crt_hs_s};
            A_CRT_H3: prdata = {21'd0, crt_h_bnd};
            A_CRT_V1: prdata = {6'd0, crt_v_act, 6'd0, crt_v_last};
            A_CRT_V2: prdata = {6'd0, crt_vs_e, 6'd0, crt_vs_s};
            A_CRT_LN: prdata = {6'd0, crt_line_lim, 6'd0, crt_prep};
            A_CRT_MD: prdata = {5'd0, crt_int_w, 14'd0, crt_dbly, crt_dblx};
            A_FRAME:  prdata = {15'd0, flip_pend, frame_cnt};
            default:  prdata = 32'd0;
        endcase
    end

endmodule
