`timescale 1ns / 1ps
// Sample log: one 32-bit entry per send, in block RAM.
//
// Entry = latency in ticks (lat at lat_valid), or 0xFFFFFFFF for a timeout.
// Entries are written in order from index 0 until N are stored; later
// outcomes are dropped (full). clear empties the log; the RAM contents are
// left, n_samples says how many are valid. Read port: rd_data is mem[rd_addr]
// one clock later.

module sample_log #(
  parameter int N = 4096
) (
  input  logic                 clk,
  input  logic                 rst,
  input  logic                 clear,
  input  logic                 lat_valid,
  input  logic [31:0]          lat,
  input  logic                 timed_out,
  input  logic [$clog2(N)-1:0] rd_addr,
  output logic [31:0]          rd_data,
  output logic [31:0]          n_samples,
  output logic                 full
);

  localparam int AW = $clog2(N);

  (* ram_style = "block" *) logic [31:0] mem [0:N-1];

  wire we = (lat_valid || timed_out) && n_samples < 32'(N);

  always_ff @(posedge clk)
    if (we)
      mem[n_samples[AW-1:0]] <= timed_out ? 32'hFFFF_FFFF : lat;

  always_ff @(posedge clk)
    rd_data <= mem[rd_addr];

  always_ff @(posedge clk) begin
    if (rst || clear)
      n_samples <= '0;
    else if (we)
      n_samples <= n_samples + 32'd1;
  end

  assign full = (n_samples == 32'(N));

endmodule
