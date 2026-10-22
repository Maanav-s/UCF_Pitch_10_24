`timescale 1ns / 1ps
// Sequential binary to BCD (double dabble), one bit per clock.
//
// start loads bin; W clocks later done pulses and bcd holds D decimal digits,
// least significant digit in bcd[3:0]. D = 10 covers any 32-bit value.

module bin2bcd #(
  parameter int W = 32,
  parameter int D = 10
) (
  input  logic           clk,
  input  logic           rst,
  input  logic           start,  // ignored while busy
  input  logic [W-1:0]   bin,
  output logic [4*D-1:0] bcd,
  output logic           busy,
  output logic           done
);

  // Works on a local copy: Vivado synthesis ignores assignments to a
  // function's input argument (Synth 8-6104), though simulators honor them.
  function automatic logic [4*D-1:0] add3(input logic [4*D-1:0] b);
    logic [4*D-1:0] r;
    r = b;
    for (int d = 0; d < D; d++)
      if (r[4*d +: 4] >= 4'd5)
        r[4*d +: 4] = r[4*d +: 4] + 4'd3;
    return r;
  endfunction

  logic [W-1:0]             sh;
  logic [$clog2(W + 1)-1:0] n;

  always_ff @(posedge clk) begin
    done <= 1'b0;
    if (rst) begin
      busy <= 1'b0;
      bcd  <= '0;
      sh   <= '0;
      n    <= '0;
    end else if (!busy) begin
      if (start) begin
        sh   <= bin;
        bcd  <= '0;
        n    <= '0;
        busy <= 1'b1;
      end
    end else begin
      {bcd, sh} <= {add3(bcd), sh} << 1;
      n         <= n + 1'b1;
      if (n == W - 1) begin
        busy <= 1'b0;
        done <= 1'b1;
      end
    end
  end

endmodule
