`timescale 1ns / 1ps
// Board top for the two-trader exchange (docs/mm_protocol.md): the exchange
// with two LAN8720 ports (JB to the laptop, JC to the FPGA trader) and the
// FPGA trader with its own LAN8720 (JXADC), all on one Basys3.
//
// Clocks: the exchange runs on clk_ex, 50 MHz from the 100 MHz oscillator
// through an MMCM. Each LAN8720 module provides its own 50 MHz REF_CLK:
// l_ref_clk and f_ref_clk clock only the RMII halves of the two exchange
// ports (rmii_port crosses to clk_ex through xpm_fifo_async), t_ref_clk
// clocks the whole trader. The four clocks are unrelated. Buttons and
// switches are synchronized into each domain that uses them; LEDs and the
// display are driven by registers of their own domain and mixed at the pins.
//
// Controls
//   BTNC       send the next AAPL print of the script
//   BTND       play the rest of the script, 1 s apart
//   BTNR       dump the event log over the USB-UART (115200 8N1)
//   BTNU       clear exchange and trader
//   BTNL       hold: the display shows the trader's half-spread
//   SW[1:0]    display: 00 laptop-minus-FPGA gap for the last print (us),
//              01 FPGA latency, 10 laptop latency, 11 fill count.
//              XX.XX below 100 us, whole us above, ---- without data.
//   SW[5:2]    trader half-spread in dollars (0 counts as 1)
//   SW[13]     trader taker-only (no quotes)
//   SW[15:14]  run label in the dump
//
// LEDs
//   LED0  exchange busy        LED8   book has an ask
//   LED1  FPGA's reply first   LED9   trader pickoff buy sent
//   LED2  laptop's reply first LED10  trader pickoff sell sent
//   LED3  script finished      LED11  trader got a frame it does not understand
//   LED4  port L receive       LED12  event log full
//   LED5  port F receive       LED13  trader PHY receive
//   LED6  auto-play running    LED14  exchange got a bad frame
//   LED7  book has a bid       LED15  dump in progress

module mm_top #(
  parameter int GAP_CLKS           = 100_000_000, // 2 s between auto-played prints
  parameter int REQUOTE_DELAY_CLKS = 25_000_000,  // FPGA trader holds stale quotes 0.5 s
  parameter int LOG_N              = 1024,
  parameter int BAUD               = 115200,
  parameter int DEBOUNCE_CLKS      = 500_000,     // 10 ms; testbenches shorten it
  parameter bit TX_NEGEDGE         = 1'b0
) (
  input  logic        clk100,      // W5

  // Exchange port L: LAN8720 on JB
  input  logic        l_ref_clk,   // JB[0]
  input  logic        l_crs_dv,    // JB[1]
  input  logic [1:0]  l_rxd,       // JB[3:2]
  output logic        l_tx_en,     // JB[4]
  output logic [1:0]  l_txd,       // JB[6:5]

  // Exchange port F: LAN8720 on JC
  input  logic        f_ref_clk,   // JC[0]
  input  logic        f_crs_dv,    // JC[1]
  input  logic [1:0]  f_rxd,       // JC[3:2]
  output logic        f_tx_en,     // JC[4]
  output logic [1:0]  f_txd,       // JC[6:5]

  // Trader: LAN8720 on JXADC
  input  logic        t_ref_clk,   // JXADC[0]
  input  logic        t_crs_dv,    // JXADC[1]
  input  logic [1:0]  t_rxd,       // JXADC[3:2]
  output logic        t_tx_en,     // JXADC[4]
  output logic [1:0]  t_txd,       // JXADC[6:5]

  input  logic        btnC,
  input  logic        btnU,
  input  logic        btnD,
  input  logic        btnR,
  input  logic        btnL,
  output logic        rs_tx,
  input  logic [15:0] sw,
  output logic [15:0] led,
  output logic [6:0]  seg,
  output logic        dp,
  output logic [3:0]  an
);

  // ---------------------------------------------------------------- exchange clock, reset

  logic clk100_b, clk_ex, clk_ex_unbuf, clkfb, clkfb_b, locked;

  IBUF u_ibuf100 (.I(clk100), .O(clk100_b));

  // 100 MHz x 10 / 1 = 1000 MHz VCO, / 20 = 50 MHz.
  MMCME2_BASE #(
    .BANDWIDTH          ("OPTIMIZED"),
    .CLKFBOUT_MULT_F    (10.0),
    .CLKFBOUT_PHASE     (0.0),
    .CLKIN1_PERIOD      (10.0),
    .CLKOUT0_DIVIDE_F   (20.0),
    .CLKOUT0_DUTY_CYCLE (0.5),
    .CLKOUT0_PHASE      (0.0),
    .CLKOUT1_DIVIDE     (1),
    .CLKOUT2_DIVIDE     (1),
    .CLKOUT3_DIVIDE     (1),
    .CLKOUT4_DIVIDE     (1),
    .CLKOUT5_DIVIDE     (1),
    .CLKOUT6_DIVIDE     (1),
    .CLKOUT4_CASCADE    ("FALSE"),
    .DIVCLK_DIVIDE      (1),
    .REF_JITTER1        (0.0),
    .STARTUP_WAIT       ("FALSE")
  ) u_mmcm (
    .CLKOUT0   (clk_ex_unbuf),
    .CLKOUT0B  (),
    .CLKOUT1   (),
    .CLKOUT1B  (),
    .CLKOUT2   (),
    .CLKOUT2B  (),
    .CLKOUT3   (),
    .CLKOUT3B  (),
    .CLKOUT4   (),
    .CLKOUT5   (),
    .CLKOUT6   (),
    .CLKFBOUT  (clkfb),
    .CLKFBOUTB (),
    .LOCKED    (locked),
    .CLKIN1    (clk100_b),
    .PWRDWN    (1'b0),
    .RST       (1'b0),
    .CLKFBIN   (clkfb_b)
  );

  BUFG u_bufg_fb (.I(clkfb), .O(clkfb_b));
  BUFG u_bufg_ex (.I(clk_ex_unbuf), .O(clk_ex));

  // Reset held until the MMCM is locked and for 16 clocks after.
  logic        locked_s;
  logic [15:0] rst_sr = '1;
  logic        rst_ex = 1'b1;

  xpm_cdc_single #(
    .DEST_SYNC_FF   (2),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_INPUT_REG  (0)
  ) u_locked_sync (
    .src_clk  (1'b0),
    .src_in   (locked),
    .dest_clk (clk_ex),
    .dest_out (locked_s)
  );

  always_ff @(posedge clk_ex) begin
    if (!locked_s)
      rst_sr <= '1;
    else
      rst_sr <= {rst_sr[14:0], 1'b0};
    rst_ex <= rst_sr[15];
  end

  // ---------------------------------------------------------------- exchange inputs

  logic        next_step, play, clear, dump_start;
  logic [15:0] sw_ex;

  debounce #(.CLKS(DEBOUNCE_CLKS)) u_db_c (.clk(clk_ex), .rst(rst_ex), .btn_async(btnC), .level(), .rise(next_step));
  debounce #(.CLKS(DEBOUNCE_CLKS)) u_db_d (.clk(clk_ex), .rst(rst_ex), .btn_async(btnD), .level(), .rise(play));
  debounce #(.CLKS(DEBOUNCE_CLKS)) u_db_u (.clk(clk_ex), .rst(rst_ex), .btn_async(btnU), .level(), .rise(clear));
  debounce #(.CLKS(DEBOUNCE_CLKS)) u_db_r (.clk(clk_ex), .rst(rst_ex), .btn_async(btnR), .level(), .rise(dump_start));

  xpm_cdc_array_single #(
    .DEST_SYNC_FF   (2),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_INPUT_REG  (0),
    .WIDTH          (16)
  ) u_sw_ex (
    .src_clk  (1'b0),
    .src_in   (sw),
    .dest_clk (clk_ex),
    .dest_out (sw_ex)
  );

  // ---------------------------------------------------------------- exchange

  logic        l_clk, f_clk;
  logic        l_rx_active, f_rx_active;
  logic        ex_busy, dump_busy, script_done, play_active, bid_valid, ask_valid;
  logic        log_full, rx_bad_seen, race_valid, f_first;
  logic [31:0] n_steps, n_fills, lat_f, lat_l, gap;

  BUFG u_bufg_l (.I(l_ref_clk), .O(l_clk));
  BUFG u_bufg_f (.I(f_ref_clk), .O(f_clk));

  mm_exchange #(
    .GAP_CLKS   (GAP_CLKS),
    .LOG_N      (LOG_N),
    .CLK_HZ     (50_000_000),
    .BAUD       (BAUD),
    .TX_NEGEDGE (TX_NEGEDGE)
  ) u_ex (
    .clk         (clk_ex),
    .rst         (rst_ex),
    .next_step   (next_step),
    .play        (play),
    .clear       (clear),
    .dump_start  (dump_start),
    .label       (sw_ex[15:14]),
    .l_clk       (l_clk),
    .l_crs_dv    (l_crs_dv),
    .l_rxd       (l_rxd),
    .l_tx_en     (l_tx_en),
    .l_txd       (l_txd),
    .l_rx_active (l_rx_active),
    .f_clk       (f_clk),
    .f_crs_dv    (f_crs_dv),
    .f_rxd       (f_rxd),
    .f_tx_en     (f_tx_en),
    .f_txd       (f_txd),
    .f_rx_active (f_rx_active),
    .rs_tx       (rs_tx),
    .dump_busy   (dump_busy),
    .busy        (ex_busy),
    .script_done (script_done),
    .play_active (play_active),
    .bid_valid   (bid_valid),
    .ask_valid   (ask_valid),
    .log_full    (log_full),
    .rx_bad_seen (rx_bad_seen),
    .n_steps     (n_steps),
    .n_fills     (n_fills),
    .race_valid  (race_valid),
    .f_first     (f_first),
    .lat_f       (lat_f),
    .lat_l       (lat_l),
    .gap         (gap)
  );

  // ---------------------------------------------------------------- trader clock, reset, inputs

  logic clk_tr;

  BUFG u_bufg_t (.I(t_ref_clk), .O(clk_tr));

  logic [4:0] por_tr = '1;
  logic       rst_tr = 1'b1;

  always_ff @(posedge clk_tr) begin
    if (por_tr != 0)
      por_tr <= por_tr - 5'd1;
    rst_tr <= (por_tr != 0);
  end

  logic        tr_clear, show_hs;
  logic [15:0] sw_tr;

  debounce #(.CLKS(DEBOUNCE_CLKS)) u_db_u_tr (.clk(clk_tr), .rst(rst_tr), .btn_async(btnU), .level(),        .rise(tr_clear));
  debounce #(.CLKS(DEBOUNCE_CLKS)) u_db_l    (.clk(clk_ex), .rst(rst_ex), .btn_async(btnL), .level(show_hs), .rise());

  xpm_cdc_array_single #(
    .DEST_SYNC_FF   (2),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_INPUT_REG  (0),
    .WIDTH          (16)
  ) u_sw_tr (
    .src_clk  (1'b0),
    .src_in   (sw),
    .dest_clk (clk_tr),
    .dest_out (sw_tr)
  );

  // ---------------------------------------------------------------- trader

  logic        tr_buy, tr_sell, tr_rx_crs;
  logic [31:0] tr_n_ignored;

  mm_trader #(.TX_NEGEDGE(TX_NEGEDGE), .REQUOTE_DELAY_CLKS(REQUOTE_DELAY_CLKS)) u_tr (
    .clk                 (clk_tr),
    .rst                 (rst_tr),
    .clear               (tr_clear),
    .half_spread_dollars (sw_tr[5:2]),
    .quoting             (!sw_tr[13]),
    .rmii_crs_dv         (t_crs_dv),
    .rmii_rxd            (t_rxd),
    .rmii_tx_en          (t_tx_en),
    .rmii_txd            (t_txd),
    .buy                 (tr_buy),
    .sell                (tr_sell),
    .quote_sent          (),
    .n_md                (),
    .n_buys              (),
    .n_sells             (),
    .n_fills             (),
    .n_ignored           (tr_n_ignored),
    .rx_crs              (tr_rx_crs),
    .tx_active           ()
  );

  // ---------------------------------------------------------------- display (clk_ex)

  // Latency in us from clk_ex ticks (20 ns): XX.XX below 100 us, whole us
  // above. ticks / 50 = (ticks * 1342178) >> 26, exact below 500,000.
  localparam logic [20:0] DIV50_K = 21'd1342178;

  logic [31:0] sel_ticks, sel_d;
  logic        is_latency, is_latency_d, blank_d, blank_dd;
  logic [39:0] us_prod;
  logic [13:0] disp_val;
  logic [3:0]  disp_dp;

  always_ff @(posedge clk_ex) begin
    is_latency <= (sw_ex[1:0] != 2'b11);
    blank_d    <= (sw_ex[1:0] != 2'b11) && !race_valid;
    case (sw_ex[1:0])
      2'b00:   sel_ticks <= gap;
      2'b01:   sel_ticks <= lat_f;
      2'b10:   sel_ticks <= lat_l;
      default: sel_ticks <= n_fills;
    endcase

    us_prod      <= sel_ticks[18:0] * DIV50_K;
    sel_d        <= sel_ticks;
    is_latency_d <= is_latency;
    blank_dd     <= blank_d;

    disp_dp <= 4'b0000;
    if (show_hs) begin
      // half-spread in dollars as XX.XX
      disp_val <= 14'((sw_ex[5:2] == 4'd0) ? 4'd1 : sw_ex[5:2]) * 14'd100;
      disp_dp  <= 4'b0100;
    end else if (!is_latency_d) begin
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
    .clk     (clk_ex),
    .rst     (rst_ex),
    .value   (disp_val),
    .blank   (blank_dd && !show_hs),
    .dp_mask (disp_dp),
    .seg     (seg),
    .dp      (dp),
    .an      (an)
  );

  // ---------------------------------------------------------------- LEDs

  localparam int STRETCH = 2_500_000;  // about 50 ms
  logic [21:0] buy_cnt, sell_cnt, trx_cnt;
  logic [15:0] led_ex, led_tr;

  always_ff @(posedge clk_tr) begin
    if (rst_tr) begin
      buy_cnt  <= '0;
      sell_cnt <= '0;
      trx_cnt  <= '0;
    end else begin
      if (tr_buy)                buy_cnt  <= 22'(STRETCH);
      else if (buy_cnt != 0)     buy_cnt  <= buy_cnt - 22'd1;
      if (tr_sell)               sell_cnt <= 22'(STRETCH);
      else if (sell_cnt != 0)    sell_cnt <= sell_cnt - 22'd1;
      if (tr_rx_crs)             trx_cnt  <= 22'(STRETCH);
      else if (trx_cnt != 0)     trx_cnt  <= trx_cnt - 22'd1;
    end
    led_tr     <= '0;
    led_tr[9]  <= (buy_cnt != 0);
    led_tr[10] <= (sell_cnt != 0);
    led_tr[11] <= (tr_n_ignored != 0);
    led_tr[13] <= (trx_cnt != 0);
  end

  always_ff @(posedge clk_ex) begin
    led_ex     <= '0;
    led_ex[0]  <= ex_busy;
    led_ex[1]  <= race_valid && f_first;
    led_ex[2]  <= race_valid && !f_first;
    led_ex[3]  <= script_done;
    led_ex[6]  <= play_active;
    led_ex[7]  <= bid_valid;
    led_ex[8]  <= ask_valid;
    led_ex[12] <= log_full;
    led_ex[14] <= rx_bad_seen;
    led_ex[15] <= dump_busy;
  end

  // Activity LEDs are registered in their PHY domains (rmii_port).
  assign led = led_ex | led_tr | {10'd0, f_rx_active, l_rx_active, 4'd0};

endmodule
