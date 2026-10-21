`timescale 1ns / 1ps
// Board 1 top level: FPGA exchange on a LAN8720 RMII module on JB.
//
// Sends the stored FIX market-data frame and shows the round-trip latency to
// the end of the trader's reply (see exchange_core). Everything runs on the
// LAN8720's 50 MHz reference clock, so 1 tick = 20 ns.
//
// Controls
//   BTNC        send the market data once
//   BTNU        clear statistics
//   SW[15]      send continuously, 1 ms after each reply or timeout
//   SW[1:0]     display: 00 last, 01 min, 10 max latency in us,
//               11 reply count. Latency shows as XX.XX below 100 us and as
//               whole us (e.g. 0153) from 100 us on. "----" until the first
//               reply.
//
// LEDs
//   LED0   waiting for a reply
//   LED1   last send got its reply
//   LED2   last send timed out (10 ms)
//   LED3   a frame that is not the reply was received (since BTNU)
//   LED4   CRS_DV activity (receive)
//   LED5   transmit activity
//   LED14  a matching reply arrived with no send pending (since BTNU)
//   LED15  continuous sending on

module exchange (
  input  logic        rmii_ref_clk,  // JB[0], 50 MHz from the LAN8720 module
  input  logic        rmii_crs_dv,   // JB[1]
  input  logic [1:0]  rmii_rxd,      // JB[3:2]
  output logic        rmii_tx_en,    // JB[4]
  output logic [1:0]  rmii_txd,      // JB[6:5]

  input  logic        btnC,
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

  logic send, clear;
  logic [15:0] sw_s;

  debounce u_db_c (.clk(clk), .rst(rst), .btn_async(btnC), .level(), .rise(send));
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

  // ---------------------------------------------------------------- exchange

  logic        waiting, lat_valid, last_ok, last_timeout, rx_crs, tx_active;
  logic [31:0] lat_last, lat_min, lat_max;
  logic [31:0] n_replies, n_timeouts, n_other, n_stale;

  exchange_core u_core (
    .clk          (clk),
    .rst          (rst),
    .send         (send),
    .auto_send    (sw_s[15]),
    .clear        (clear),
    .rmii_crs_dv  (rmii_crs_dv),
    .rmii_rxd     (rmii_rxd),
    .rmii_tx_en   (rmii_tx_en),
    .rmii_txd     (rmii_txd),
    .waiting      (waiting),
    .lat_valid    (lat_valid),
    .lat_last     (lat_last),
    .lat_min      (lat_min),
    .lat_max      (lat_max),
    .n_replies    (n_replies),
    .n_timeouts   (n_timeouts),
    .n_other      (n_other),
    .n_stale      (n_stale),
    .last_ok      (last_ok),
    .last_timeout (last_timeout),
    .rx_crs       (rx_crs),
    .tx_active    (tx_active)
  );

  // ---------------------------------------------------------------- display

  // Latency in us: XX.XX below 100 us, whole us from 100 us on (spec §7).
  // 1 tick = 20 ns, so hundredths of a us = 2 * ticks, and us = ticks / 50.
  // ticks / 50 is computed as (ticks * 1342178) >> 26, which is exact for
  // every ticks below 500,000 (10 ms, the reply timeout). Three register
  // stages; the values change rarely, so their latency does not matter.
  localparam logic [20:0] DIV50_K = 21'd1342178;

  logic [31:0] sel_ticks, sel_d;
  logic        is_latency, is_latency_d;
  logic [39:0] us_prod;
  logic [13:0] disp_val;
  logic [3:0]  disp_dp;

  always_ff @(posedge clk) begin
    is_latency <= (sw_s[1:0] != 2'b11);
    case (sw_s[1:0])
      2'b00:   sel_ticks <= lat_last;
      2'b01:   sel_ticks <= lat_min;
      2'b10:   sel_ticks <= lat_max;
      default: sel_ticks <= n_replies;
    endcase

    us_prod      <= sel_ticks[18:0] * DIV50_K;
    sel_d        <= sel_ticks;
    is_latency_d <= is_latency;

    disp_dp <= 4'b0000;
    if (!is_latency_d) begin
      disp_val <= (sel_d > 32'd9999) ? 14'd9999 : sel_d[13:0];
    end else if (sel_d < 32'd5000) begin
      disp_val <= {sel_d[12:0], 1'b0};
      disp_dp  <= 4'b0100;
    end else if (sel_d < 32'd500_000) begin
      disp_val <= us_prod[39:26];
    end else begin
      disp_val <= 14'd9999;
    end
  end

  sevenseg u_seg (
    .clk     (clk),
    .rst     (rst),
    .value   (disp_val),
    .blank   (is_latency_d && n_replies == 0),
    .dp_mask (disp_dp),
    .seg     (seg),
    .dp      (dp),
    .an      (an)
  );

  // ---------------------------------------------------------------- LEDs

  // Stretch activity to about 50 ms so single frames are visible. (TX uses
  // tx_active, not the TX_EN pin, so the TX_EN register can sit in its IOB.)
  localparam int STRETCH = 2_500_000;
  logic [21:0] rx_led_cnt, tx_led_cnt;

  always_ff @(posedge clk) begin
    if (rst) begin
      rx_led_cnt <= '0;
      tx_led_cnt <= '0;
    end else begin
      if (rx_crs)              rx_led_cnt <= 22'(STRETCH);
      else if (rx_led_cnt != 0) rx_led_cnt <= rx_led_cnt - 22'd1;
      if (tx_active)           tx_led_cnt <= 22'(STRETCH);
      else if (tx_led_cnt != 0) tx_led_cnt <= tx_led_cnt - 22'd1;
    end
  end

  always_ff @(posedge clk) begin
    led     <= '0;
    led[0]  <= waiting;
    led[1]  <= last_ok;
    led[2]  <= last_timeout;
    led[3]  <= (n_other != 0);
    led[4]  <= (rx_led_cnt != 0);
    led[5]  <= (tx_led_cnt != 0);
    led[14] <= (n_stale != 0);
    led[15] <= sw_s[15];
  end

endmodule
