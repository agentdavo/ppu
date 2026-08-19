// Hard-macro stub so synthesis does not try to infer 200x32 of flops for the
// scanbufs. Real area comes from the LEF (GF180.md 6.4), added in the report.
(* blackbox *) (* keep *)
module gf180mcu_fd_ip_sram__sram256x8m8wm1 (
    input  wire       CLK, CEN, GWEN,
    input  wire [7:0] WEN,
    input  wire [7:0] A,
    input  wire [7:0] D,
    output wire [7:0] Q
);
endmodule

(* blackbox *) (* keep *)
module gf180mcu_fd_ip_sram__sram512x8m8wm1 (
    input  wire       CLK, CEN, GWEN,
    input  wire [7:0] WEN,
    input  wire [8:0] A,
    input  wire [7:0] D,
    output wire [7:0] Q
);
endmodule
