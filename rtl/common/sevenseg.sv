`timescale 1ns / 1ps
// Basys3 4-digit 7-segment display: shows value (0-9999) in decimal, or
// "----" when blank is high. dp_mask[i] lights the decimal point after digit
// i (digit 0 is the rightmost). All outputs are active low.
//
// The binary-to-BCD conversion runs sequentially (shift-and-add-3, 14 clocks)
// and restarts as soon as it finishes, so the display follows value within
// a few clocks.

module sevenseg #(
  parameter int REFRESH_BITS = 17  // each digit lit 2^(REFRESH_BITS-2) clocks
) (
  input  logic        clk,
  input  logic        rst,
  input  logic [13:0] value,
  input  logic        blank,
  input  logic [3:0]  dp_mask,
  output logic [6:0]  seg,   // {g, f, e, d, c, b, a}
  output logic        dp,
  output logic [3:0]  an
);

  // ---------------------------------------------------------------- BCD

  logic [13:0] bin;
  logic [15:0] bcd, bcd_out;
  logic [3:0]  step;
  logic [29:0] nxt;   // {bcd, bin} after this step's add-3 and shift

  // Works on a local copy: Vivado synthesis ignores assignments to a
  // function's input argument (Synth 8-6104), though simulators honor them.
  function automatic logic [15:0] add3(input logic [15:0] b);
    logic [15:0] r;
    r = b;
    for (int d = 0; d < 4; d++)
      if (r[4*d +: 4] >= 4'd5)
        r[4*d +: 4] = r[4*d +: 4] + 4'd3;
    return r;
  endfunction

  assign nxt = {add3(bcd), bin} << 1;

  always_ff @(posedge clk) begin
    if (rst) begin
      bin     <= '0;
      bcd     <= '0;
      bcd_out <= '0;
      step    <= '0;
    end else if (step == 4'd0) begin
      bin  <= (value > 14'd9999) ? 14'd9999 : value;
      bcd  <= '0;
      step <= 4'd1;
    end else begin
      {bcd, bin} <= nxt;
      if (step == 4'd14) begin
        bcd_out <= nxt[29:14];
        step    <= 4'd0;
      end else begin
        step <= step + 4'd1;
      end
    end
  end

  // ---------------------------------------------------------------- scan

  logic [REFRESH_BITS-1:0] scan;
  wire  [1:0]              digit = scan[REFRESH_BITS-1 -: 2];
  wire  [3:0]              nib   = bcd_out[4*digit +: 4];

  always_ff @(posedge clk) begin
    if (rst)
      scan <= '0;
    else
      scan <= scan + 1'b1;
  end

  always_ff @(posedge clk) begin
    an <= ~(4'b0001 << digit);
    dp <= ~dp_mask[digit];
    if (blank)
      seg <= 7'b0111111;  // only g lit: "-"
    else
      case (nib)
        4'd0: seg <= 7'b1000000;
        4'd1: seg <= 7'b1111001;
        4'd2: seg <= 7'b0100100;
        4'd3: seg <= 7'b0110000;
        4'd4: seg <= 7'b0011001;
        4'd5: seg <= 7'b0010010;
        4'd6: seg <= 7'b0000010;
        4'd7: seg <= 7'b1111000;
        4'd8: seg <= 7'b0000000;
        4'd9: seg <= 7'b0010000;
        default: seg <= 7'b1111111;
      endcase
  end

endmodule
