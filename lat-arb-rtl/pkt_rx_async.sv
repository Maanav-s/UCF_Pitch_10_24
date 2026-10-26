`timescale 1ns / 1ps
// Copy of pkt_rx that crosses a completed UDP payload from the PHY clock
// (wr_clk) into the exchange clock (rd_clk) with xpm_fifo_async.
//
// Use this on the PC port when the JA LAN8720 has its own 50 MHz REF_CLK.
// pkt_rx and rmii_rx stay on wr_clk. The book reads pay / pay_len / pkt_valid
// on rd_clk. The FPGA-sniper port does not need this: it shares JB's clock.
//
// pkt_rx.sv is unchanged.

module pkt_rx_async
  import lat_arb_pkg::*;
#(
  parameter int DEPTH = 16
) (
  input  logic        wr_clk,
  input  logic        wr_rst,
  input  logic        rd_clk,
  input  logic        rd_rst,

  input  logic        rmii_crs_dv,
  input  logic [1:0]  rmii_rxd,
  input  logic [47:0] our_mac,
  input  logic [31:0] our_ip,

  output logic        pkt_valid,
  output logic [5:0]  pay_len,
  output logic [7:0]  pay [0:MAX_PAY-1],
  output logic        rx_crs
);

  localparam int W = 6 + 8 * MAX_PAY;

  logic        wr_valid;
  logic [5:0]  wr_len;
  logic [7:0]  wr_pay [0:MAX_PAY-1];
  logic        wr_crs;

  pkt_rx u_rx (
    .clk        (wr_clk),
    .rst        (wr_rst),
    .rmii_crs_dv(rmii_crs_dv),
    .rmii_rxd   (rmii_rxd),
    .our_mac    (our_mac),
    .our_ip     (our_ip),
    .pkt_valid  (wr_valid),
    .pay_len    (wr_len),
    .pay        (wr_pay),
    .rx_crs     (wr_crs)
  );

  logic [W-1:0] din, dout;
  logic         full, empty, rd_en;

  always_comb begin
    din[5:0] = wr_len;
    for (int i = 0; i < MAX_PAY; i++)
      din[6 + 8 * i +: 8] = wr_pay[i];
  end

  xpm_fifo_async #(
    .CDC_SYNC_STAGES     (3),
    .DOUT_RESET_VALUE    ("0"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_MEMORY_TYPE    ("auto"),
    .FIFO_READ_LATENCY   (0),
    .FIFO_WRITE_DEPTH    (DEPTH),
    .FULL_RESET_VALUE    (0),
    .PROG_EMPTY_THRESH   (5),
    .PROG_FULL_THRESH    (DEPTH - 5),
    .RD_DATA_COUNT_WIDTH (5),
    .READ_DATA_WIDTH     (W),
    .READ_MODE           ("fwft"),
    .RELATED_CLOCKS      (0),
    .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0707"),
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (W),
    .WR_DATA_COUNT_WIDTH (5)
  ) u_cdc (
    .almost_empty  (),
    .almost_full   (),
    .data_valid    (),
    .dbiterr       (),
    .dout          (dout),
    .empty         (empty),
    .full          (full),
    .overflow      (),
    .prog_empty    (),
    .prog_full     (),
    .rd_data_count (),
    .rd_rst_busy   (),
    .sbiterr       (),
    .underflow     (),
    .wr_ack        (),
    .wr_data_count (),
    .wr_rst_busy   (),
    .din           (din),
    .injectdbiterr (1'b0),
    .injectsbiterr (1'b0),
    .rd_clk        (rd_clk),
    .rd_en         (rd_en),
    .rst           (wr_rst),
    .sleep         (1'b0),
    .wr_clk        (wr_clk),
    .wr_en         (wr_valid && !full)
  );

  always_ff @(posedge rd_clk) begin
    if (rd_rst) begin
      pkt_valid <= 1'b0;
      rd_en     <= 1'b0;
      pay_len   <= '0;
    end else begin
      pkt_valid <= 1'b0;
      rd_en     <= 1'b0;
      if (!empty && !rd_en) begin
        pay_len   <= dout[5:0];
        for (int i = 0; i < MAX_PAY; i++)
          pay[i] <= dout[6 + 8 * i +: 8];
        pkt_valid <= 1'b1;
        rd_en     <= 1'b1;
      end
    end
  end

  xpm_cdc_single #(
    .DEST_SYNC_FF  (3),
    .INIT_SYNC_FF  (1),
    .SIM_ASSERT_CHK(0),
    .SRC_INPUT_REG (1)
  ) u_crs (
    .src_clk  (wr_clk),
    .src_in   (wr_crs),
    .dest_clk (rd_clk),
    .dest_out (rx_crs)
  );

endmodule
