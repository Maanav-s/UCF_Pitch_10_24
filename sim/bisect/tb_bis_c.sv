`timescale 1ns / 1ps
// Bisect testbench: bare instance of tc_bis_c.

module tb_bis_c;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #10 clk = ~clk;

  logic        tx_en;
  logic [1:0]  txd;
  logic [31:0] limit, n_md, n_buys, n_ignored, n_sent, n_cut;
  logic        buy, no_trade, rx_crs, tx_active;

  tc_bis_c dut (
    .clk         (clk),
    .rst         (rst),
    .sel         (2'd0),
    .k           (12'd0),
    .clear       (1'b0),
    .rmii_crs_dv (1'b0),
    .rmii_rxd    (2'b00),
    .rmii_tx_en  (tx_en),
    .rmii_txd    (txd),
    .limit       (limit),
    .buy         (buy),
    .no_trade    (no_trade),
    .n_md        (n_md),
    .n_buys      (n_buys),
    .n_ignored   (n_ignored),
    .n_sent      (n_sent),
    .n_cut       (n_cut),
    .rx_crs      (rx_crs),
    .tx_active   (tx_active)
  );

  initial begin
    repeat (10) @(posedge clk);
    rst = 1'b0;
    repeat (100) @(posedge clk);
    $display("TB_BIS_C PASS");
    $finish;
  end

endmodule
