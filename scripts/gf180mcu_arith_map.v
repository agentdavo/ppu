/* Teach Yosys to build adders out of the cells gf180mcu actually has.
 *
 * The library ships `addf` (full adder, 72.44 um2) and `addh` (half adder,
 * 39.51 um2) and the default flow uses NEITHER: `synth` expands $alu into
 * generic gates and abc then maps those, arriving at xor3 + carry logic. This
 * intercepts $alu before that expansion and emits a ripple-carry chain of real
 * addf cells instead.
 *
 * Usage (see scripts/synth.ys):
 *     synth -top X -flatten -run :fine
 *     techmap -map scripts/gf180mcu_arith_map.v
 *     synth -top X -flatten -run fine:
 *
 * WHETHER IT IS WORTH IT IS AN EXPERIMENT, NOT AN ASSUMPTION. The arithmetic
 * here is 8% cheaper per bit in isolation (72.44 against ~79 for xor3 + carry),
 * but abc gets to optimise ACROSS a gate-level adder -- constant inputs,
 * unused high bits, comparisons that share the subtractor -- and it cannot do
 * that through an addf instance. The number that matters is the whole netlist,
 * which is why synth.sh reports it.
 *
 * Ripple carry is the right structure at 25 MHz: 19 bits of addf CI->CO is
 * comfortably inside a 40 ns period, and carry-select/lookahead would cost the
 * area this is trying to save.
 */

(* techmap_celltype = "$alu" *)
module _80_gf180mcu_alu (A, B, CI, BI, X, Y, CO);
	parameter A_SIGNED = 0;
	parameter B_SIGNED = 0;
	parameter A_WIDTH = 1;
	parameter B_WIDTH = 1;
	parameter Y_WIDTH = 1;

	(* force_downto *)
	input [A_WIDTH-1:0] A;
	(* force_downto *)
	input [B_WIDTH-1:0] B;
	(* force_downto *)
	output [Y_WIDTH-1:0] X, Y;

	input CI, BI;
	(* force_downto *)
	output [Y_WIDTH-1:0] CO;

	/* Below three bits an addf chain cannot beat what abc does with the
	 * surrounding logic, and incrementers degenerate to half adders anyway. */
	wire _TECHMAP_FAIL_ = Y_WIDTH < 3;

	(* force_downto *)
	wire [Y_WIDTH-1:0] A_buf, B_buf;
	\$pos #(.A_SIGNED(A_SIGNED), .A_WIDTH(A_WIDTH), .Y_WIDTH(Y_WIDTH)) A_conv (.A(A), .Y(A_buf));
	\$pos #(.A_SIGNED(B_SIGNED), .A_WIDTH(B_WIDTH), .Y_WIDTH(Y_WIDTH)) B_conv (.A(B), .Y(B_buf));

	(* force_downto *)
	wire [Y_WIDTH-1:0] AA = A_buf;
	(* force_downto *)
	wire [Y_WIDTH-1:0] BB = BI ? ~B_buf : B_buf;

	/* $alu's X is the propagate term; the subtractor path needs it. */
	assign X = AA ^ BB;

	(* force_downto *)
	wire [Y_WIDTH:0] carry;
	assign carry[0] = CI;

	genvar i;
	generate for (i = 0; i < Y_WIDTH; i = i + 1) begin : slice
		gf180mcu_fd_sc_mcu7t5v0__addf_1 fa (
			.A (AA[i]),
			.B (BB[i]),
			.CI(carry[i]),
			.S (Y[i]),
			.CO(carry[i + 1])
		);
		assign CO[i] = carry[i + 1];
	end endgenerate
endmodule
