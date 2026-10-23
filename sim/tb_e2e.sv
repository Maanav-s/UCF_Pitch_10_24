`timescale 1ns / 1ps
// End-to-end testbench: exchange_core (board 1) and trader_core (board 2)
// joined by their RMII wires, as on the bench with two LAN8720 modules and a
// cable, minus the PHY and cable delays.
//
// Two pairs run side by side:
//   pair 0: trader SPECULATIVE_TX = 0, exchange EXACT_MATCH = 1, so the
//           reply must be REPLY_FRAME byte for byte.
//   pair 1: trader SPECULATIVE_TX = 1, exchange EXACT_MATCH = 0 (the UDP
//           checksum is 0 in this mode, which EXACT_MATCH = 0 ignores).
//
// Tests
//   1. Limit $100.00: 5 sends on each pair, all replies, no timeouts, no
//      other frames. Every latency in a pair is the same, and pair 1 is
//      faster than pair 0.
//   2. Limit $99.99: the trader does not buy, so the send times out. Pair 1
//      also sends a cut-off reply, which the exchange counts in n_other.
//
// Prints "TB_E2E PASS" or "TB_E2E FAIL (<n> errors)" at the end.

module tb_e2e;

  localparam real CLK_PERIOD   = 20.0;
  localparam int  TIMEOUT_CLKS = 5000;
  localparam int  GAP_CLKS     = 100;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #(CLK_PERIOD / 2) clk = ~clk;

  int errors = 0;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      $display("ERROR %0t: %s", $time, msg);
      errors++;
    end
  endtask

  logic        send = 1'b0;
  logic [11:0] k    = 12'd4000;  // $100.00

  logic [31:0] lat_last [2], lat_min [2], lat_max [2];
  logic [31:0] n_replies [2], n_timeouts [2], n_other [2];
  logic [31:0] n_buys [2];
  logic        waiting [2];

  for (genvar p = 0; p < 2; p++) begin : g_pair
    wire       ex_tx_en, tr_tx_en;
    wire [1:0] ex_txd, tr_txd;

    exchange_core #(
      .TIMEOUT_CLKS (TIMEOUT_CLKS),
      .GAP_CLKS     (GAP_CLKS),
      .EXACT_MATCH  (p == 0)
    ) ex (
      .clk          (clk),
      .rst          (rst),
      .send         (send),
      .auto_send    (1'b0),
      .clear        (1'b0),
      .run_start    (1'b0),
      .hold         (1'b0),
      .rmii_crs_dv  (tr_tx_en),
      .rmii_rxd     (tr_txd),
      .rmii_tx_en   (ex_tx_en),
      .rmii_txd     (ex_txd),
      .waiting      (waiting[p]),
      .lat_valid    (),
      .timed_out    (),
      .stats_clear  (),
      .run_active   (),
      .run_done     (),
      .lat_last     (lat_last[p]),
      .lat_min      (lat_min[p]),
      .lat_max      (lat_max[p]),
      .n_replies    (n_replies[p]),
      .n_timeouts   (n_timeouts[p]),
      .n_other      (n_other[p]),
      .n_stale      (),
      .last_ok      (),
      .last_timeout (),
      .rx_crs       (),
      .tx_active    ()
    );

    trader_core #(.SPECULATIVE_TX(p == 1)) tr (
      .clk         (clk),
      .rst         (rst),
      .sel         (2'd0),
      .k           (k),
      .clear       (1'b0),
      .rmii_crs_dv (ex_tx_en),
      .rmii_rxd    (ex_txd),
      .rmii_tx_en  (tr_tx_en),
      .rmii_txd    (tr_txd),
      .limit       (),
      .buy         (),
      .no_trade    (),
      .n_md        (),
      .n_buys      (n_buys[p]),
      .n_ignored   (),
      .n_sent      (),
      .n_cut       (),
      .rx_crs      (),
      .tx_active   ()
    );
  end

  // Pulse send on both exchanges and wait until both are done.
  task automatic do_send();
    @(negedge clk);
    send = 1'b1;
    @(negedge clk);
    send = 1'b0;
    repeat (5) @(posedge clk);
    @(posedge clk iff !waiting[0] && !waiting[1]);
    repeat (GAP_CLKS + 1000) @(posedge clk);
  endtask

  initial begin
    repeat (5) @(posedge clk);
    rst = 1'b0;
    repeat (5) @(posedge clk);

    $display("Test 1: limit $100.00, 5 sends");
    for (int i = 0; i < 5; i++)
      do_send();
    for (int p = 0; p < 2; p++) begin
      check(n_replies[p] == 5 && n_timeouts[p] == 0 && n_other[p] == 0,
            $sformatf("pair %0d: replies %0d, timeouts %0d, other %0d; expected 5, 0, 0",
                      p, n_replies[p], n_timeouts[p], n_other[p]));
      check(n_buys[p] == 5, $sformatf("pair %0d: trader buys %0d, expected 5", p, n_buys[p]));
      check(lat_min[p] == lat_max[p],
            $sformatf("pair %0d: latency varies, min %0d max %0d", p, lat_min[p], lat_max[p]));
      $display("  pair %0d (SPECULATIVE_TX = %0d): %0d ticks = %0.2f us", p, p,
               lat_last[p], lat_last[p] * CLK_PERIOD / 1000.0);
    end
    check(lat_last[1] < lat_last[0], "speculative trader is not faster");

    $display("Test 2: limit $99.99, no trade");
    k = 12'd3999;
    do_send();
    for (int p = 0; p < 2; p++)
      check(n_replies[p] == 5 && n_timeouts[p] == 1,
            $sformatf("pair %0d: replies %0d, timeouts %0d; expected 5, 1",
                      p, n_replies[p], n_timeouts[p]));
    check(n_other[0] == 0, $sformatf("pair 0: other %0d, expected 0", n_other[0]));
    check(n_other[1] == 1, $sformatf("pair 1: other %0d, expected 1 (cut-off reply)", n_other[1]));

    if (errors == 0)
      $display("TB_E2E PASS");
    else
      $display("TB_E2E FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #(5ms);
    $display("TB_E2E FAIL (watchdog)");
    $finish;
  end

endmodule
