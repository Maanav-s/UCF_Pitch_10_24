`timescale 1ns / 1ps
// Testbench helper: the PHY side of one RMII link.
//
//   - Captures every frame the DUT transmits (TX_EN/TXD, sampled with clk,
//     through an rmii_rx instance) into cap[n][offset] with its length (FCS
//     included) in cap_len[n]. n_cap counts captured frames; the testbench
//     keeps its own n_read.
//   - send(fr, n) drives fr[0..n-1] (FCS included) into the DUT's
//     CRS_DV/RXD the way a LAN8720 does: a few 00 dibits with CRS_DV high,
//     preamble, SFD, data LSB dibit first, then CRS_DV low. Pins change on
//     the falling edge of clk so the DUT samples them cleanly.
//
// clk must be the clock the DUT's RMII pins are synchronous to (its REF_CLK).

module mm_tb_port #(
  parameter int MAXF   = 128,
  parameter int STRIDE = 160
) (
  input  logic       clk,
  input  logic       dut_tx_en,
  input  logic [1:0] dut_txd,
  output logic       dut_crs_dv,
  output logic [1:0] dut_rxd
);

  initial begin
    dut_crs_dv = 1'b0;
    dut_rxd    = 2'b00;
  end

  // ---------------------------------------------------------------- capture

  logic rst = 1'b1;
  initial begin
    repeat (4) @(posedge clk);
    rst = 1'b0;
  end

  logic        rx_valid, rx_eof;
  logic [7:0]  rx_data;
  logic [10:0] rx_offset, rx_len;

  rmii_rx u_mon (
    .clk         (clk),
    .rst         (rst),
    .rmii_crs_dv (dut_tx_en),
    .rmii_rxd    (dut_txd),
    .rx_valid    (rx_valid),
    .rx_data     (rx_data),
    .rx_offset   (rx_offset),
    .rx_eof      (rx_eof),
    .rx_len      (rx_len),
    .rx_crs      ()
  );

  logic [7:0] cap     [0:MAXF-1][0:STRIDE-1];
  int         cap_len [0:MAXF-1];
  int         n_cap = 0;

  always @(posedge clk) begin
    if (rx_valid && n_cap < MAXF && rx_offset < STRIDE)
      cap[n_cap][rx_offset] <= rx_data;
    if (rx_eof && n_cap < MAXF) begin
      cap_len[n_cap] <= rx_len;
      n_cap          <= n_cap + 1;
    end
  end

  // ---------------------------------------------------------------- drive

  task automatic send(input logic [7:0] fr [0:STRIDE-1], input int n);
    logic [7:0] b;
    @(negedge clk);
    dut_crs_dv = 1'b1;
    dut_rxd    = 2'b00;
    repeat (3) @(negedge clk);
    for (int k = 0; k < 8 + n; k++) begin
      b = (k < 7) ? 8'h55 : (k == 7) ? 8'hD5 : fr[k - 8];
      for (int d = 0; d < 4; d++) begin
        dut_rxd = b[2*d +: 2];
        @(negedge clk);
      end
    end
    dut_crs_dv = 1'b0;
    dut_rxd    = 2'b00;
    // Inter-frame gap, as a PHY would leave between frames.
    repeat (48) @(negedge clk);
  endtask

endmodule
