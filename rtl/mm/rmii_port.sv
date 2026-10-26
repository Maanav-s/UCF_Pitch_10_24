`timescale 1ns / 1ps
// One exchange Ethernet port: RMII receiver and transmitter on the PHY's
// 50 MHz REF_CLK (phy_clk), joined to the exchange clock (clk) through
// xpm_fifo_async instances. The FIFOs are the only logic that touches both
// clocks; the two domains are otherwise unrelated.
//
// Receive (PHY -> exchange), cut-through: every byte rmii_rx produces is
// written into a 10-bit FIFO as {eof, dv, data}; at the frame end a word
// with eof = 1 is written. The exchange side reads as soon as a word is
// there and reproduces rmii_rx's interface: rx_valid/rx_data per byte, then
// rx_eof in a later cycle. The exchange parses frames on the fly, so a
// frame's acceptance is a few clocks after its last byte.
//
// Transmit (exchange -> PHY), store and forward: the exchange writes a whole
// frame (destination MAC to end of payload, no FCS) into a 9-bit data FIFO
// as {last, data}, then one token into a second FIFO. The PHY side waits for
// a token and only then streams the frame into rmii_tx, so rmii_tx never
// underruns. rmii_tx adds preamble, FCS and the inter-frame gap.
//
// The RX data FIFO is 2048 words (one full-size frame is 1518 bytes); the TX
// data FIFO 2048 bytes holds about 14 of this design's frames. tx_ready goes
// low when it is full or when the token FIFO (16 entries) is full.
//
// Resets: phy_rst is generated here from a power-on counter on phy_clk; rst
// is the exchange's reset. Each FIFO is reset from its write-side clock, as
// xpm_fifo_async requires, and its wr_rst_busy / rd_rst_busy outputs gate
// the first accesses.

module rmii_port #(
  parameter bit TX_NEGEDGE = 1'b0
) (
  // PHY side
  input  logic        phy_clk,
  input  logic        rmii_crs_dv,
  input  logic [1:0]  rmii_rxd,
  output logic        rmii_tx_en,
  output logic [1:0]  rmii_txd,
  output logic        phy_rx_active,   // phy_clk: CRS_DV seen, stretched ~50 ms
  output logic        phy_tx_active,   // phy_clk: transmitting, stretched ~50 ms

  // Exchange side
  input  logic        clk,
  input  logic        rst,
  output logic        rx_valid,
  output logic [7:0]  rx_data,
  output logic        rx_eof,
  input  logic        tx_valid,
  input  logic [7:0]  tx_data,
  input  logic        tx_last,
  output logic        tx_ready
);

  // ---------------------------------------------------------------- PHY reset

  logic [4:0] por = '1;
  logic       phy_rst = 1'b1;

  always_ff @(posedge phy_clk) begin
    if (por != 0)
      por <= por - 5'd1;
    phy_rst <= (por != 0);
  end

  // ---------------------------------------------------------------- RMII RX

  logic        p_rx_valid, p_rx_eof, p_rx_crs;
  logic [7:0]  p_rx_data;

  rmii_rx u_rx (
    .clk         (phy_clk),
    .rst         (phy_rst),
    .rmii_crs_dv (rmii_crs_dv),
    .rmii_rxd    (rmii_rxd),
    .rx_valid    (p_rx_valid),
    .rx_data     (p_rx_data),
    .rx_offset   (),
    .rx_eof      (p_rx_eof),
    .rx_len      (),
    .rx_crs      (p_rx_crs)
  );

  // RX FIFO: written on phy_clk, read on clk.
  logic       rxf_wr_rst_busy, rxf_rd_rst_busy, rxf_full, rxf_empty, rxf_rd_en;
  logic [9:0] rxf_dout;

  wire rxf_wr_en = (p_rx_valid || p_rx_eof) && !rxf_wr_rst_busy && !rxf_full;

  xpm_fifo_async #(
    .CDC_SYNC_STAGES     (2),
    .DOUT_RESET_VALUE    ("0"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_MEMORY_TYPE    ("block"),
    .FIFO_READ_LATENCY   (0),
    .FIFO_WRITE_DEPTH    (2048),
    .FULL_RESET_VALUE    (0),
    .PROG_EMPTY_THRESH   (10),
    .PROG_FULL_THRESH    (10),
    .RD_DATA_COUNT_WIDTH (1),
    .READ_DATA_WIDTH     (10),
    .READ_MODE           ("fwft"),
    .RELATED_CLOCKS      (0),
    .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0000"),
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (10),
    .WR_DATA_COUNT_WIDTH (1)
  ) u_rx_fifo (
    .sleep         (1'b0),
    .rst           (phy_rst),
    .wr_clk        (phy_clk),
    .wr_en         (rxf_wr_en),
    .din           ({p_rx_eof, p_rx_valid, p_rx_data}),
    .full          (rxf_full),
    .prog_full     (),
    .wr_data_count (),
    .overflow      (),
    .wr_rst_busy   (rxf_wr_rst_busy),
    .almost_full   (),
    .wr_ack        (),
    .rd_clk        (clk),
    .rd_en         (rxf_rd_en),
    .dout          (rxf_dout),
    .empty         (rxf_empty),
    .prog_empty    (),
    .rd_data_count (),
    .underflow     (),
    .rd_rst_busy   (rxf_rd_rst_busy),
    .almost_empty  (),
    .data_valid    (),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       ()
  );

  // Exchange-side reader. A word that carries both a byte and the end of
  // frame (rmii_rx never produces one, but the FIFO format allows it) is
  // delivered as the byte first and the eof in the next cycle.
  logic rx_eof_pending;

  wire rxf_word   = !rxf_empty && !rxf_rd_rst_busy && !rst;
  wire rxf_w_eof  = rxf_dout[9];
  wire rxf_w_dv   = rxf_dout[8];

  assign rxf_rd_en = rxf_word && !rx_eof_pending;

  always_ff @(posedge clk) begin
    rx_valid <= 1'b0;
    rx_eof   <= 1'b0;
    rx_data  <= rxf_dout[7:0];
    if (rst) begin
      rx_eof_pending <= 1'b0;
    end else if (rx_eof_pending) begin
      rx_eof         <= 1'b1;
      rx_eof_pending <= 1'b0;
    end else if (rxf_rd_en) begin
      if (rxf_w_dv) begin
        rx_valid       <= 1'b1;
        rx_eof_pending <= rxf_w_eof;
      end else begin
        rx_eof <= rxf_w_eof;
      end
    end
  end

  // ---------------------------------------------------------------- TX FIFOs

  // Data FIFO: written on clk, read on phy_clk.
  logic       txf_wr_rst_busy, txf_rd_rst_busy, txf_full, txf_empty, txf_rd_en;
  logic [8:0] txf_dout;
  // Token FIFO: one entry per complete frame in the data FIFO.
  logic       tok_wr_rst_busy, tok_rd_rst_busy, tok_full, tok_empty, tok_rd_en;

  assign tx_ready = !txf_full && !tok_full && !txf_wr_rst_busy && !tok_wr_rst_busy && !rst;

  wire txf_wr_en = tx_valid && tx_ready;
  wire tok_wr_en = txf_wr_en && tx_last;

  xpm_fifo_async #(
    .CDC_SYNC_STAGES     (2),
    .DOUT_RESET_VALUE    ("0"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_MEMORY_TYPE    ("block"),
    .FIFO_READ_LATENCY   (0),
    .FIFO_WRITE_DEPTH    (2048),
    .FULL_RESET_VALUE    (0),
    .PROG_EMPTY_THRESH   (10),
    .PROG_FULL_THRESH    (10),
    .RD_DATA_COUNT_WIDTH (1),
    .READ_DATA_WIDTH     (9),
    .READ_MODE           ("fwft"),
    .RELATED_CLOCKS      (0),
    .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0000"),
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (9),
    .WR_DATA_COUNT_WIDTH (1)
  ) u_tx_fifo (
    .sleep         (1'b0),
    .rst           (rst),
    .wr_clk        (clk),
    .wr_en         (txf_wr_en),
    .din           ({tx_last, tx_data}),
    .full          (txf_full),
    .prog_full     (),
    .wr_data_count (),
    .overflow      (),
    .wr_rst_busy   (txf_wr_rst_busy),
    .almost_full   (),
    .wr_ack        (),
    .rd_clk        (phy_clk),
    .rd_en         (txf_rd_en),
    .dout          (txf_dout),
    .empty         (txf_empty),
    .prog_empty    (),
    .rd_data_count (),
    .underflow     (),
    .rd_rst_busy   (txf_rd_rst_busy),
    .almost_empty  (),
    .data_valid    (),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       ()
  );

  xpm_fifo_async #(
    .CDC_SYNC_STAGES     (2),
    .DOUT_RESET_VALUE    ("0"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_MEMORY_TYPE    ("distributed"),
    .FIFO_READ_LATENCY   (0),
    .FIFO_WRITE_DEPTH    (16),
    .FULL_RESET_VALUE    (0),
    .PROG_EMPTY_THRESH   (3),
    .PROG_FULL_THRESH    (3),
    .RD_DATA_COUNT_WIDTH (1),
    .READ_DATA_WIDTH     (1),
    .READ_MODE           ("fwft"),
    .RELATED_CLOCKS      (0),
    .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0000"),
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (1),
    .WR_DATA_COUNT_WIDTH (1)
  ) u_tok_fifo (
    .sleep         (1'b0),
    .rst           (rst),
    .wr_clk        (clk),
    .wr_en         (tok_wr_en),
    .din           (1'b1),
    .full          (tok_full),
    .prog_full     (),
    .wr_data_count (),
    .overflow      (),
    .wr_rst_busy   (tok_wr_rst_busy),
    .almost_full   (),
    .wr_ack        (),
    .rd_clk        (phy_clk),
    .rd_en         (tok_rd_en),
    .dout          (),
    .empty         (tok_empty),
    .prog_empty    (),
    .rd_data_count (),
    .underflow     (),
    .rd_rst_busy   (tok_rd_rst_busy),
    .almost_empty  (),
    .data_valid    (),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       ()
  );

  // ---------------------------------------------------------------- RMII TX

  logic       t_valid, t_last, t_ready, t_busy;
  logic [7:0] t_data;
  logic       sending;  // a token has been taken; streaming its frame

  assign tok_rd_en = !sending && !tok_empty && !tok_rd_rst_busy && !phy_rst;

  assign t_valid   = sending && !txf_empty && !txf_rd_rst_busy;
  assign t_data    = txf_dout[7:0];
  assign t_last    = txf_dout[8];
  assign txf_rd_en = t_valid && t_ready;

  always_ff @(posedge phy_clk) begin
    if (phy_rst)
      sending <= 1'b0;
    else if (tok_rd_en)
      sending <= 1'b1;
    else if (txf_rd_en && t_last)
      sending <= 1'b0;
  end

  rmii_tx #(.TX_NEGEDGE(TX_NEGEDGE)) u_tx (
    .clk         (phy_clk),
    .rst         (phy_rst),
    .tx_valid    (t_valid),
    .tx_data     (t_data),
    .tx_last     (t_last),
    .tx_ready    (t_ready),
    .tx_busy     (t_busy),
    .tx_underrun (),
    .rmii_tx_en  (rmii_tx_en),
    .rmii_txd    (rmii_txd)
  );

  // ---------------------------------------------------------------- activity

  localparam int STRETCH = 2_500_000;  // about 50 ms
  logic [21:0] rx_cnt, tx_cnt;

  always_ff @(posedge phy_clk) begin
    if (phy_rst) begin
      rx_cnt <= '0;
      tx_cnt <= '0;
    end else begin
      if (p_rx_crs)          rx_cnt <= 22'(STRETCH);
      else if (rx_cnt != 0)  rx_cnt <= rx_cnt - 22'd1;
      if (t_busy)            tx_cnt <= 22'(STRETCH);
      else if (tx_cnt != 0)  tx_cnt <= tx_cnt - 22'd1;
    end
    phy_rx_active <= (rx_cnt != 0);
    phy_tx_active <= (tx_cnt != 0);
  end

endmodule
