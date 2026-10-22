`timescale 1ns / 1ps
// Board 2 top level: FPGA trader on a LAN8720 RMII module on JB.
//
// Answers the exchange's FIX market data with a FIX buy order when the
// trading rule holds (see trader_core). Everything runs on the LAN8720's
// 50 MHz reference clock, like the exchange.
//
// The exchange's stored market data is AAPL, offer, $100.00. With the
// default LIMIT_BASE of $60.00 the limit range is $60.00-$100.95, so it buys
// with SW[1:0] = 00 (AAPL) and a limit of at least $100.00 (k >= 4000:
// SW[13:2] = 1111 1010 0000 or higher, e.g. all on).
//
// Controls
//   BTNU        clear the counters
//   SW[1:0]     ticker: 00 AAPL, 01 MSFT, 10 NVDA, 11 TSLA
//   SW[13:2]    limit step k: limit = $60.00 + k * $0.01
//   SW[15]      display: 0 limit in dollars, 1 buy count
//   Switches are taken only between frames.
//
// Display
//   SW[15] = 0: the limit, XX.XX below $100 and XXX.X (to the dime) from
//   $100 on.
//   SW[15] = 1: buys since BTNU (saturates at 9999).
//
// LEDs
//   LED0   buy (stretched to about 50 ms)
//   LED1   no trade: valid market data, rule says no (stretched)
//   LED3   a frame that is not market data was received (since BTNU)
//   LED4   CRS_DV activity (receive)
//   LED5   transmit activity
//   LED12  a reply was cut off with a wrong FCS (since BTNU). With
//          SPECULATIVE_TX this is every frame that is not a buy.
//   LED15  SPECULATIVE_TX build

module board2_eth_top #(
  parameter bit          SPECULATIVE_TX = 1'b0,
  parameter logic [31:0] LIMIT_BASE     = 32'd600_000,  // $60.00, multiple of 100
  parameter logic [31:0] LIMIT_STEP     = 32'd100       // $0.01, multiple of 100
) (
  input  logic        rmii_ref_clk,  // JB[0], 50 MHz from the LAN8720 module
  input  logic        rmii_crs_dv,   // JB[1]
  input  logic [1:0]  rmii_rxd,      // JB[3:2]
  output logic        rmii_tx_en,    // JB[4]
  output logic [1:0]  rmii_txd,      // JB[6:5]

  input  logic        btnU,
  input  logic [15:0] sw,
  output logic [15:0] led,
  output logic [6:0]  seg,
  output logic        dp,
  output logic [3:0]  an
);

  // ---------------------------------------------------------------- clock, reset

  logic clk;

  BUFG u_bufg (.I(rmii_ref_clk), .O(clk));

  logic [4:0] por = '1;
  logic       rst = 1'b1;

  always_ff @(posedge clk) begin
    if (por != 0)
      por <= por - 5'd1;
    rst <= (por != 0);
  end

  // ---------------------------------------------------------------- inputs

  logic        clear;
  logic [15:0] sw_s;

  debounce u_db_u (.clk(clk), .rst(rst), .btn_async(btnU), .level(), .rise(clear));

  xpm_cdc_array_single #(
    .DEST_SYNC_FF   (2),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_INPUT_REG  (0),
    .WIDTH          (16)
  ) u_sw_sync (
    .src_clk  (1'b0),
    .src_in   (sw),
    .dest_clk (clk),
    .dest_out (sw_s)
  );

  // ---------------------------------------------------------------- trader

  logic        buy, no_trade, rx_crs, tx_active;
  logic [31:0] n_md, n_buys, n_ignored, n_sent, n_cut;

  trader_core #(
    .SPECULATIVE_TX (SPECULATIVE_TX),
    .LIMIT_BASE     (LIMIT_BASE),
    .LIMIT_STEP     (LIMIT_STEP)
  ) u_core (
    .clk         (clk),
    .rst         (rst),
    .sel         (sw_s[1:0]),
    .k           (sw_s[13:2]),
    .clear       (clear),
    .rmii_crs_dv (rmii_crs_dv),
    .rmii_rxd    (rmii_rxd),
    .rmii_tx_en  (rmii_tx_en),
    .rmii_txd    (rmii_txd),
    .limit       (),
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

  // ---------------------------------------------------------------- display

  // Limit in cents, from the switches. XX.XX below 10000 cents, else cents / 10
  // as XXX.X. x / 10 is computed as (x * 838861) >> 23, exact for x below
  // 4,000,000. Register stages; the values change rarely.
  localparam logic [19:0] DIV10_K = 20'd838861;

  logic [31:0] cents;
  logic [42:0] dimes_prod;
  logic        show_buys;
  logic [13:0] disp_val;
  logic [3:0]  disp_dp;

  always_ff @(posedge clk) begin
    cents      <= LIMIT_BASE / 100 + 32'(sw_s[13:2]) * (LIMIT_STEP / 100);
    dimes_prod <= cents[22:0] * DIV10_K;
    show_buys  <= sw_s[15];

    disp_dp <= 4'b0000;
    if (show_buys) begin
      disp_val <= (n_buys > 32'd9999) ? 14'd9999 : n_buys[13:0];
    end else if (cents < 32'd10_000) begin
      disp_val <= cents[13:0];
      disp_dp  <= 4'b0100;
    end else if (cents < 32'd100_000) begin
      disp_val <= dimes_prod[36:23];
      disp_dp  <= 4'b0010;
    end else begin
      disp_val <= 14'd9999;
    end
  end

  sevenseg u_seg (
    .clk     (clk),
    .rst     (rst),
    .value   (disp_val),
    .blank   (1'b0),
    .dp_mask (disp_dp),
    .seg     (seg),
    .dp      (dp),
    .an      (an)
  );

  // ---------------------------------------------------------------- LEDs

  // Stretch events to about 50 ms so single frames are visible.
  localparam int STRETCH = 2_500_000;
  logic [21:0] buy_cnt, nt_cnt, rx_led_cnt, tx_led_cnt;

  always_ff @(posedge clk) begin
    if (rst) begin
      buy_cnt    <= '0;
      nt_cnt     <= '0;
      rx_led_cnt <= '0;
      tx_led_cnt <= '0;
    end else begin
      if (buy)                  buy_cnt <= 22'(STRETCH);
      else if (buy_cnt != 0)    buy_cnt <= buy_cnt - 22'd1;
      if (no_trade)             nt_cnt <= 22'(STRETCH);
      else if (nt_cnt != 0)     nt_cnt <= nt_cnt - 22'd1;
      if (rx_crs)               rx_led_cnt <= 22'(STRETCH);
      else if (rx_led_cnt != 0) rx_led_cnt <= rx_led_cnt - 22'd1;
      if (tx_active)            tx_led_cnt <= 22'(STRETCH);
      else if (tx_led_cnt != 0) tx_led_cnt <= tx_led_cnt - 22'd1;
    end
  end

  always_ff @(posedge clk) begin
    led     <= '0;
    led[0]  <= (buy_cnt != 0);
    led[1]  <= (nt_cnt != 0);
    led[3]  <= (n_ignored != 0);
    led[4]  <= (rx_led_cnt != 0);
    led[5]  <= (tx_led_cnt != 0);
    led[12] <= (n_cut != 0);
    led[15] <= SPECULATIVE_TX;
  end

endmodule
