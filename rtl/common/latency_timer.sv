`timescale 1ns / 1ps
// Latency timer: counts clock edges from a start pulse to a stop pulse.
//
// ticks = (edge that samples stop) - (edge that samples start). So with a
// 50 MHz clock, one tick is 20 ns. start and stop must be synchronous to clk;
// the caller makes them single-cycle pulses.
//
//   - start: (re)starts the measurement, even if one is running.
//   - stop while running: ticks is loaded and done pulses.
//   - TIMEOUT ticks without stop: timeout pulses and the timer stops.
//     ticks is not changed.
//   - stop while not running is ignored.

module latency_timer #(
  parameter int W       = 32,
  parameter int TIMEOUT = 500_000  // ticks; 10 ms at 50 MHz
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         start,
  input  logic         stop,
  output logic         running,
  output logic         done,     // one-cycle pulse, ticks valid from here
  output logic         timeout,  // one-cycle pulse
  output logic [W-1:0] ticks
);

  logic [W-1:0] cnt;  // ticks elapsed after the current edge

  always_ff @(posedge clk) begin
    if (rst) begin
      running <= 1'b0;
      done    <= 1'b0;
      timeout <= 1'b0;
      cnt     <= '0;
      ticks   <= '0;
    end else begin
      done    <= 1'b0;
      timeout <= 1'b0;
      if (start) begin
        running <= 1'b1;
        cnt     <= W'(1);
      end else if (running) begin
        if (stop) begin
          running <= 1'b0;
          done    <= 1'b1;
          ticks   <= cnt;
        end else if (cnt == W'(TIMEOUT)) begin
          running <= 1'b0;
          timeout <= 1'b1;
        end else begin
          cnt <= cnt + W'(1);
        end
      end
    end
  end

endmodule
