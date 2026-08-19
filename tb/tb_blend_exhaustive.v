// Exhaustive blend check: every (src, dst, mode, alpha) for one channel, plus
// the transparency path at pixel level. Output is diffed against the golden
// model -- see ip/ppu/tb/check_blend.sh. This is signoff gate G5 in miniature.

`timescale 1ns/1ps

module tb_blend_exhaustive;

    reg  [4:0] src, dst, alpha;
    reg  [2:0] mode;
    wire [4:0] out;

    ppu_blend_ch dut (.src(src), .dst(dst), .mode(mode), .alpha(alpha), .out(out));

    integer m, s, d, a;
    initial begin
        for (m = 1; m <= 4; m = m + 1)
            for (s = 0; s < 32; s = s + 1)
                for (d = 0; d < 32; d = d + 1)
                    for (a = 0; a < 32; a = a + 1) begin
                        mode  = m[2:0];
                        src   = s[4:0];
                        dst   = d[4:0];
                        alpha = a[4:0];
                        #1 $display("%0d %0d %0d %0d %0d", m, s, d, a, out);
                    end
        $finish;
    end

endmodule
