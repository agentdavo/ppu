// PPU top level: 640x480@60 out, 320x240 internal, 1 px/clk; a programmable
// CRTC adds linear-framebuffer modes. Core and pixel clocks are locked, so
// there is no clock-domain crossing. Output is digital RGB555 plus syncs.

`include "ppu_defs.vh"

module ppu_top (
    input  wire        clk,          // core AND pixel
    input  wire        rst_n,

    // APB control
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire  [7:0] paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        halted,

    // External SRAM, 16-bit, shared bidirectional data bus.
    output wire        mem_req,
    output wire        mem_we,
    output wire [18:0] mem_addr,
    output wire [15:0] mem_wdata,
    input  wire        mem_ack,
    input  wire [15:0] mem_rdata,

    // Framebuffer read port: burst master on the SoC memory controller. One
    // request per scanline; the stream may arrive late and may stall
    // mid-burst -- see ppu_fbscan.v.
    output wire        fb_burst_req,
    output wire [31:0] fb_burst_addr,   // system address
    output wire [10:0] fb_burst_len,    // 32-bit beats
    input  wire        fb_burst_gnt,
    input  wire        fb_burst_valid,
    input  wire [31:0] fb_burst_data,

    // Bus release, for a shared external SRAM behind an on-die arbiter.
    // These are internal wires and never reach a pad. If the mechanism is
    // unused, DRIVE mem_hreq low: an undriven input is X, `if (!mem_hreq)`
    // takes the else branch on X, and the bus is handed to a master that
    // does not exist -- nothing fetches and the display holds its last line.
    input  wire        mem_hreq,     // host wants the external bus
    output wire        mem_hgnt,     // PPU is off it; host may drive
    output wire        mem_oe,       // pad output-enable for addr/ctrl/wdata

    // Digital RGB555 video out
    output wire        hsync,
    output wire        vsync,
    output wire        de,
    output wire  [4:0] vid_r,
    output wire  [4:0] vid_g,
    output wire  [4:0] vid_b,

    // Status
    output wire        underrun,
    output wire        irq
);

    // -------------------------------------------------------------------- CSR
    wire        enable, pc_load, halt_hsync, halt_vsync;
    wire [18:0] pc_in;
    wire        cfg_dig_en, cfg_hsync_pol, cfg_vsync_pol;
    wire        underrun_clr;
    wire        pram_we_csr, pram_re_csr;
    wire  [7:0] pram_addr_csr;
    wire [15:0] pram_wdata_csr;
    wire        underrun_w, busy_w, vblank_w;
    wire [18:0] host_addr;
    wire [15:0] host_wdata;
    wire        host_wreq, host_rreq;
    wire        host_ack;
    wire  [8:0] render_y;
    wire        fb_en;
    wire  [2:0] fb_fmt;
    wire [31:0] fb_base;
    wire [15:0] fb_stride;
    wire  [9:0] fb_w, fb_h;
    wire [10:0] crt_h_last, crt_h_act, crt_h_bnd, crt_hs_s, crt_hs_e, crt_int_w;
    wire  [9:0] crt_v_last, crt_v_act, crt_vs_s, crt_vs_e, crt_prep, crt_line_lim;
    wire        crt_dblx, crt_dbly;
    // Declared before u_csr: strict SystemVerilog elaborators do not permit
    // the old implicit-forward-net behaviour used by plain Verilog.
    wire        vsync_raw, frame_restart;
    wire        f_req, f_ack;
    wire [15:0] pal_colour;
    reg         grant_host;

    ppu_csr u_csr (
        .clk(clk), .rst_n(rst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .prdata(prdata), .pready(pready),
        .ppu_enable(enable), .pc_load(pc_load), .pc_out(pc_in),
        .halt_hsync(halt_hsync), .halt_vsync(halt_vsync),
        .cfg_dig_en(cfg_dig_en),
        .cfg_hsync_pol(cfg_hsync_pol), .cfg_vsync_pol(cfg_vsync_pol),
        .fb_en(fb_en), .fb_fmt(fb_fmt), .fb_base(fb_base),
        .fb_stride(fb_stride), .fb_w(fb_w), .fb_h(fb_h),
        .crt_h_last(crt_h_last), .crt_h_act(crt_h_act), .crt_h_bnd(crt_h_bnd),
        .crt_hs_s(crt_hs_s), .crt_hs_e(crt_hs_e),
        .crt_v_last(crt_v_last), .crt_v_act(crt_v_act),
        .crt_vs_s(crt_vs_s), .crt_vs_e(crt_vs_e),
        .crt_prep(crt_prep), .crt_line_lim(crt_line_lim),
        .crt_dblx(crt_dblx), .crt_dbly(crt_dbly), .crt_int_w(crt_int_w),
        .pram_we(pram_we_csr), .pram_re(pram_re_csr),
        .pram_addr(pram_addr_csr), .pram_wdata(pram_wdata_csr),
        .pram_rdata(pal_colour),
        .mem_addr(host_addr), .mem_wdata(host_wdata),
        .mem_wreq(host_wreq), .mem_wack(host_ack), .mem_rdata_in(mem_rdata),
        .mem_rreq(host_rreq),
        .bus_stall_i(f_req && !f_ack), .bus_fetch_i(f_ack),
        .halted(halted), .underrun(underrun_w), .underrun_clr(underrun_clr),
        .busy(busy_w), .render_y(render_y), .vblank(vsync_raw),
        .frame_tick(frame_restart),
        .irq(irq)
    );

    assign underrun = underrun_w;

    // ------------------------------------------------------------- pixel enable
    // Core and pixel rates are equal in this configuration: pix_en is a
    // constant enable, not a clock crossing.
    wire pix_en = 1'b1;

    // ---------------------------------------------------------------- timing
    wire [9:0] int_x;
    wire [8:0] int_y;
    wire       line_tick, prep_frame, frame_start;
    wire       hsync_raw, active, active_raw, disp_req;

    ppu_timing u_timing (
        .clk(clk), .rst_n(rst_n), .enable(enable), .pix_en(pix_en),
        .cfg_h_last(crt_h_last), .cfg_h_act(crt_h_act), .cfg_h_bnd(crt_h_bnd),
        .cfg_hs_s(crt_hs_s), .cfg_hs_e(crt_hs_e),
        .cfg_v_last(crt_v_last), .cfg_v_act(crt_v_act),
        .cfg_vs_s(crt_vs_s), .cfg_vs_e(crt_vs_e),
        .cfg_prep(crt_prep), .cfg_line_lim(crt_line_lim),
        .cfg_dblx(crt_dblx), .cfg_dbly(crt_dbly),
        .hsync(hsync_raw), .vsync(vsync_raw), .active(active), .active_raw(active_raw),
        .h_count(), .v_count(),
        .int_x(int_x), .int_y(int_y),
        .line_start(line_tick), .prep_frame(prep_frame), .frame_start(frame_start)
    );

    // ------------------------------------------------------ display controller
    wire       render_start, buf_swap;
    wire [8:0] disp_addr;
    wire [31:0] sb_disp;

    // Exactly one render engine runs at a time: FB_CTRL.FB_EN picks the
    // linear framebuffer scanner, otherwise the command processor. They share
    // the line handshake, so ppu_display need not know which is behind it.
    wire       cmd_line_done, fb_line_done;
    wire       line_done  = fb_en ? fb_line_done : cmd_line_done;
    wire       cmd_enable = enable && !fb_en;

    ppu_display u_display (
        .clk(clk), .rst_n(rst_n), .enable(enable), .pix_en(pix_en),
        .line_tick(line_tick), .prep_frame(prep_frame),
        .int_x(int_x), .int_y(int_y), .active(active), .active_raw(active_raw),
        .hsync_raw(hsync_raw), .vsync_raw(vsync_raw),
        .render_start(render_start), .frame_restart(frame_restart),
        .render_y(render_y), .render_done(line_done),
        .buf_swap(buf_swap), .disp_req(disp_req), .disp_addr(disp_addr), .disp_data(sb_disp),
        .cfg_hsync_pol(cfg_hsync_pol), .cfg_vsync_pol(cfg_vsync_pol),
        .cfg_dig_en(cfg_dig_en), .busy_o(busy_w),
        .hsync(hsync), .vsync(vsync), .de(de),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .underrun(underrun_w), .underrun_clr(underrun_clr), .irq()
    );

    // ------------------------------------------------------- command processor
    wire        f_stream;
    wire [18:0] f_addr;
    wire [15:0] f_data;

    wire        px_valid, px_direct, px_prio;
    wire  [9:0] px_x;
    wire [15:0] px_word;
    wire  [1:0] px_fmt;
    wire  [3:0] px_sub;
    wire  [2:0] px_poff, px_mode;
    wire  [4:0] px_alpha;
    wire        pram_we;
    wire  [7:0] pram_addr_w;
    wire [15:0] pram_wdata;

    // ---------------------------------------------- linear framebuffer engine
    // The scanner requests a whole line per burst; on this chip an external
    // adapter walks the burst out as single beats on the flat SRAM port.
    wire        fb_sb_wr;
    wire  [8:0] fb_sb_addr;
    wire [31:0] fb_sb_data;

    ppu_fbscan u_fbscan (
        .clk(clk), .rst_n(rst_n), .enable(enable && fb_en),
        .line_start(render_start), .frame_restart(frame_restart),
        .raster_y(render_y), .line_done(fb_line_done),
        .fb_base(fb_base), .fb_stride(fb_stride),
        .fb_w(fb_w), .fb_h(fb_h), .fb_fmt(fb_fmt), .int_w(crt_int_w),
        .burst_req(fb_burst_req), .burst_addr(fb_burst_addr),
        .burst_len(fb_burst_len), .burst_gnt(fb_burst_gnt),
        .burst_valid(fb_burst_valid), .burst_data(fb_burst_data),
        .sb_wr(fb_sb_wr), .sb_addr(fb_sb_addr), .sb_data(fb_sb_data)
    );

    ppu_cmd u_cmd (
        .clk(clk), .rst_n(rst_n), .enable(cmd_enable),
        .line_start(render_start), .frame_restart(frame_restart),
        .raster_y(render_y), .line_done(cmd_line_done),
        .pc_load(pc_load), .pc_in(pc_in),
        .fetch_req(f_req), .fetch_addr(f_addr), .fetch_stream(f_stream),
        .fetch_ack(f_ack), .fetch_data(f_data),
        .px_valid(px_valid), .px_x(px_x), .px_word(px_word), .px_fmt(px_fmt),
        .px_sub(px_sub), .px_poff(px_poff), .px_mode(px_mode),
        .px_alpha(px_alpha), .px_prio(px_prio), .px_direct(px_direct),
        .pram_we(pram_we), .pram_addr(pram_addr_w), .pram_wdata(pram_wdata),
        .halted(halted), .dbg_state()
    );

    // ------------------------------------------------------------ fetch caches
    // Split by stream: the index and texel streams alternate and evict each
    // other out of a unified cache.
    wire tex_sel = (f_stream == `PPU_STREAM_TEXEL);

    wire        hit_t, hit_i, miss_t, miss_i;
    wire [15:0] rd_t, rd_i;

    ppu_cache #(.LINES(4), .AWIDTH(19), .IDXW(2)) u_cache_tex (
        .clk(clk), .rst_n(rst_n), .flush(pc_load),
        .req(f_req && tex_sel), .addr(f_addr), .hit(hit_t), .rdata(rd_t),
        .miss_req(miss_t), .miss_ack(mem_ack), .miss_data(mem_rdata)
    );

    ppu_cache #(.LINES(4), .AWIDTH(19), .IDXW(2)) u_cache_idx (
        .clk(clk), .rst_n(rst_n), .flush(pc_load),
        .req(f_req && !tex_sel), .addr(f_addr), .hit(hit_i), .rdata(rd_i),
        .miss_req(miss_i), .miss_ack(mem_ack), .miss_data(mem_rdata)
    );

    // ---------------------------------------------------------- bus arbitration
    // Two render fetch streams and the host keyhole share the flat port; the
    // framebuffer is a burst master elsewhere, not a client here. Render
    // fetches win over the host: a stalled fetch is a visible underrun, a
    // stalled host access just waits a cycle on PREADY.
    wire bus_free;              // driven by the bus-release logic below
    wire host_req  = host_wreq || host_rreq;
    // !grant_fetch is the fetch-side twin of host_go's !grant_host below, and
    // it was missing. A miss holds fetch_req high until its ack, so without
    // this term the SAME address is requested again on the ack cycle and a
    // duplicate reply arrives a cycle later: wasted bandwidth on a bus the
    // framebuffer burst master is competing for, and a correctness trap for
    // any fetch loop that issues back-to-back requests, since the stale reply
    // is indistinguishable from the next pixel's.
    wire fetch_win = (miss_t || miss_i) && !grant_fetch && bus_free;

    // The grant must be REGISTERED to match the ack: the bus is pipelined, so
    // mem_ack in cycle N answers the request made in N-1. Qualifying the ack
    // with the current cycle's priority routes replies to the wrong client.
    // A granted host access must also stop asking -- host_req stays high
    // until the ack a cycle later, and without the !grant_host term the same
    // access is issued (and a write lands) twice.
    wire host_go = host_req && !grant_host && !fetch_win && bus_free;

    assign mem_req   = fetch_win || host_go;
    assign mem_we    = !fetch_win && host_wreq && !grant_host && bus_free;
    assign mem_addr  = fetch_win ? f_addr : host_addr;
    assign mem_wdata = host_wdata;

    reg grant_fetch;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grant_host  <= 1'b0;
            grant_fetch <= 1'b0;
        end else begin
            grant_host  <= !fetch_win && host_go;
            // Deliberately a single cycle, NOT held until the reply. Holding
            // it looks more careful and deadlocks: a request that is never
            // acked -- a stalled bus, which ppu_display_tb's underrun test
            // creates on purpose -- would keep grant_fetch high, which drives
            // fetch_win and therefore mem_req low, so the ack can never come
            // and the renderer never recovers. Self-clearing means a stalled
            // fetch simply retries until the bus answers.
            grant_fetch <= fetch_win;
        end
    end

    assign host_ack = grant_host && mem_ack;
    assign f_ack    = (hit_t || hit_i) || (grant_fetch && mem_ack);
    assign f_data   = tex_sel ? rd_t : rd_i;

    // ------------------------------------------------------------ bus release
    // The host may need the external SRAM directly, so the PPU gets off the
    // bus on request. Release happens only when nothing is outstanding, so a
    // beat on the wire is never abandoned; while released, every client's
    // request is held rather than dropped, so nothing tears or hangs -- a
    // long hold just shows up as an underrun, same as a slow render.
    reg  bus_grant;
    // Idle means nothing on the wire AND nothing coming back: an address
    // latched by the SRAM this cycle still has its data in flight next cycle.
    wire bus_idle = !mem_req && !grant_fetch && !grant_host;
    assign bus_free = !bus_grant;
    assign mem_hgnt = bus_grant;
    assign mem_oe   = !bus_grant;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          bus_grant <= 1'b0;
        else if (!mem_hreq)  bus_grant <= 1'b0;
        else if (bus_idle)   bus_grant <= 1'b1;
    end

    // ------------------------------------------------------------- palette RAM
    wire [7:0]  pal_index;
    wire [15:0] unpack_direct;
    wire        unpack_is_direct;

    ppu_unpack u_unpack (
        .word(px_word), .fmt(px_fmt), .sub(px_sub), .poff(px_poff),
        .pal_index(pal_index), .direct(unpack_direct), .is_direct(unpack_is_direct)
    );

    // One port, three clients: per-pixel lookup, PALW, CSR. Writes win over
    // reads and CSR over PALW; both write sources are rare, so the blend
    // pipeline just sees a bubble on that cycle.
    ppu_pram u_pram (
        .clk(clk),
        .we   (pram_we_csr || pram_we),
        .waddr(pram_we_csr ? pram_addr_csr : pram_addr_w),
        .wdata(pram_we_csr ? pram_wdata_csr : pram_wdata),
        .re   (px_valid || pram_re_csr),
        .raddr(pram_re_csr ? pram_addr_csr : pal_index),
        .rdata(pal_colour)
    );

    // ------------------------------------------------------------- S3 register
    // The palette RAM read is synchronous: index in one cycle, colour the
    // next. The pixel record is delayed one stage to match, or paletted
    // sources land one pixel late while direct ones do not.
    reg        s3_valid, s3_bypass;
    reg  [9:0] s3_x;
    reg [15:0] s3_bypass_col;
    reg  [2:0] s3_mode;
    reg  [4:0] s3_alpha;
    reg        s3_prio;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_valid <= 1'b0;
        end else begin
            s3_valid      <= px_valid;
            s3_x          <= px_x;
            s3_mode       <= px_mode;
            s3_alpha      <= px_alpha;
            s3_prio       <= px_prio;
            s3_bypass     <= px_direct || unpack_is_direct;
            s3_bypass_col <= px_direct ? px_word : unpack_direct;
        end
    end

    // FILL supplies colour directly; ARGB1555 sources bypass the palette.
    wire [15:0] src_colour = s3_bypass ? s3_bypass_col : pal_colour;

    // ----------------------------------------------------------------- scanbuf
    // Pixel x parity -- NOT a free-running toggle -- selects the RMW phase:
    // the even pixel reads its word and is held, the odd partner blends both
    // and commits. A free-running phase bit desynchronises on spans starting
    // at an odd x, shifting the whole span by one pixel.
    //
    // A span starting on an odd x has no held partner, and one ending on an
    // even x leaves a held pixel behind: the bit-level write mask and an
    // explicit flush cover both edges.
    reg        pend_valid;
    reg  [9:0] pend_x;
    reg [15:0] pend_src;
    reg  [2:0] pend_mode;
    reg  [4:0] pend_alpha;
    reg        pend_prio;

    wire even     = !s3_x[0];
    wire do_read  =  s3_valid &&  even;
    wire do_pair  =  s3_valid && !even;                 // odd pixel completes a pair
    wire do_flush = !s3_valid &&  pend_valid;           // span ended on an even pixel
    wire pair_ok  =  pend_valid && (pend_x[9:1] == s3_x[9:1]);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pend_valid <= 1'b0;
        end else if (do_read) begin
            pend_valid <= 1'b1;
            pend_x     <= s3_x;
            pend_src   <= src_colour;
            pend_mode  <= s3_mode;
            pend_alpha <= s3_alpha;
            pend_prio  <= s3_prio;
        end else if (do_pair || do_flush) begin
            pend_valid <= 1'b0;
        end
    end

    wire [31:0] sb_rdata;
    wire [15:0] dst_lo = sb_rdata[15:0];
    wire [15:0] dst_hi = sb_rdata[31:16];

    wire [15:0] bl_lo, bl_hi;
    wire        we_lo, we_hi;

    ppu_blend u_blend_lo (
        .src(pend_src), .dst(dst_lo), .mode(pend_mode), .alpha(pend_alpha), .prio(pend_prio),
        .blended(bl_lo), .wr_en(we_lo)
    );
    ppu_blend u_blend_hi (
        .src(src_colour), .dst(dst_hi), .mode(s3_mode), .alpha(s3_alpha), .prio(s3_prio),
        .blended(bl_hi), .wr_en(we_hi)
    );

    // The two engines share the scanbuf render port. The framebuffer scanner
    // writes whole words with both pixels enabled and never reads, so in FB
    // mode the RMW cadence -- blender, palette, pairing state -- is unused.
    wire        sb_rd_req = !fb_en && do_read;
    wire        sb_wr_req = fb_en ? fb_sb_wr : (do_pair || do_flush);
    wire  [8:0] sb_waddr  = fb_en ? fb_sb_addr
                                  : (do_flush ? pend_x[9:1] : s3_x[9:1]);
    wire [31:0] sb_wdata  = fb_en ? fb_sb_data : {bl_hi, bl_lo};
    wire  [1:0] sb_wmask  = fb_en ? 2'b11
                                  : (do_flush ? {1'b0, we_lo}
                                              : {we_hi, we_lo && pair_ok});

    ppu_scanbuf u_scanbuf (
        .clk(clk), .rst_n(rst_n),
        .swap(buf_swap),
        .rd_req  (sb_rd_req),
        .wr_req  (sb_wr_req),
        .word_addr(sb_waddr),
        .wr_data (sb_wdata),
        .wr_mask (sb_wmask),
        .rd_data (sb_rdata),
        .disp_req(disp_req),
        .disp_addr(disp_addr),
        .disp_data(sb_disp)
    );

    wire _unused = &{1'b0, frame_start, pend_mode, pend_alpha, 1'b0};

endmodule


// Palette RAM, 256 x 16 b, two sram256x8 macros side by side. Single-port:
// PALW writes are rare and simply steal that cycle's read, so the blend
// pipeline sees a bubble only when a palette entry is rewritten.
module ppu_pram (
    input  wire        clk,
    input  wire        we,
    input  wire  [7:0] waddr,
    input  wire [15:0] wdata,
    input  wire        re,
    input  wire  [7:0] raddr,
    output wire [15:0] rdata
);
    wire [7:0] addr = we ? waddr : raddr;
    // CEN asserted only on an actual access.
    wire       en   = we || re;

    genvar i;
    generate
        for (i = 0; i < 2; i = i + 1) begin : lane
            gf180mcu_fd_ip_sram__sram256x8m8wm1 u_sram (
                .CLK (clk),
                .CEN (~en),
                .GWEN(~we),
                .WEN ({8{~we}}),
                .A   (addr),
                .D   (wdata[i*8 +: 8]),
                .Q   (rdata[i*8 +: 8])
            );
        end
    endgenerate
endmodule
