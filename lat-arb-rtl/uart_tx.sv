`timescale 1ns / 1ps
// UART transmitter, 8N1, LSB first.
//
// A byte is accepted on a clock edge where start is high and busy is low;
// busy stays high until its stop bit has been sent. Bit time is
// round(CLK_HZ / BAUD) clocks (434 for 50 MHz / 115200, 0.01% fast).

module uart_tx #(
  parameter int CLK_HZ = 50_000_000,
  parameter int BAUD   = 115200
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       start,
  input  logic [7:0] data,
  output logic       tx,
  output logic       busy
);

  localparam int DIV = (CLK_HZ + BAUD / 2) / BAUD;

  logic [9:0]                 sh;    // stop, data[7:0], start; sh[0] goes out next
  logic [$clog2(DIV + 1)-1:0] cnt;
  logic [3:0]                 nbit;

  always_ff @(posedge clk) begin
    if (rst) begin
      tx   <= 1'b1;
      sh   <= '1;
      busy <= 1'b0;
      cnt  <= '0;
      nbit <= '0;
    end else begin
      tx <= sh[0];
      if (!busy) begin
        if (start) begin
          sh   <= {1'b1, data, 1'b0};
          busy <= 1'b1;
          cnt  <= '0;
          nbit <= '0;
        end
      end else if (cnt == DIV - 1) begin
        cnt <= '0;
        sh  <= {1'b1, sh[9:1]};
        if (nbit == 4'd9)
          busy <= 1'b0;
        else
          nbit <= nbit + 4'd1;
      end else begin
        cnt <= cnt + 1'b1;
      end
    end
  end

endmodule
