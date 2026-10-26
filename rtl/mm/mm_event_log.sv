`timescale 1ns / 1ps
// Event log: one log_entry_t per message the exchange sends or accepts, in
// block RAM, written in order from index 0 until N are stored (later events
// are dropped: full). clear empties it. Read port for the dump: rd_data is
// the entry at rd_addr one clock later.

module mm_event_log
  import mm_pkg::*;
#(
  parameter int N = 1024
) (
  input  logic                 clk,
  input  logic                 rst,
  input  logic                 clear,
  input  logic                 we,
  input  log_entry_t           entry,
  input  logic [$clog2(N)-1:0] rd_addr,
  output log_entry_t           rd_data,
  output logic [31:0]          n_events,
  output logic                 full
);

  localparam int AW = $clog2(N);
  localparam int W  = $bits(log_entry_t);

  (* ram_style = "block" *) logic [W-1:0] mem [0:N-1];

  wire wr = we && (n_events < 32'(N));

  always_ff @(posedge clk)
    if (wr)
      mem[n_events[AW-1:0]] <= entry;

  always_ff @(posedge clk)
    rd_data <= mem[rd_addr];

  always_ff @(posedge clk) begin
    if (rst || clear)
      n_events <= '0;
    else if (wr)
      n_events <= n_events + 32'd1;
  end

  assign full = (n_events == 32'(N));

endmodule
