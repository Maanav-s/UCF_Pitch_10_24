`timescale 1ns / 1ps
// Single-board top level: the exchange and the FPGA trader on one Basys3,
// each with its own LAN8720 RMII module, joined by an Ethernet cable.
//
//   JB  exchange's LAN8720 (as in exchange.sv)
//   JC  trader's LAN8720, wired the same way: JC[0] REF_CLK, JC[1] CRS_DV,
//       JC[3:2] RXD, JC[4] TX_EN, JC[6:5] TXD
//
// Each module has its own 50 MHz oscillator, so the two halves are separate
// clock domains (clk_ex from JB[0], clk_tr from JC[0]). Nothing crosses
// between them inside the FPGA: each half synchronizes the switches and
// buttons it uses itself, and the two halves only meet at the LED and
// display pins. The traffic between them goes out through one PHY, over the
// cable and in through the other, as with two boards.
//
// Exchange controls are unchanged (see exchange.sv):
//   BTNC send, BTND run, BTNR UART dump, BTNU clear, SW15 continuous,
//   SW[14:13] run label, SW[1:0] display select, LED0-8, LED12, LED14, LED15.
//
// Trader controls (the switches the exchange does not use):
//   SW[12:11]   ticker: 00 AAPL, 01 MSFT, 10 NVDA, 11 TSLA
//   SW[10:2]    limit step k: limit = $60.00 + k * $0.10 ($60.00-$111.10)
//   BTNL        hold to show the trader's limit on the display, XX.XX below
//               $100 and XXX.X from $100 on
//   BTNU        also clears the trader's counters
//
// The exchange's stored market data is AAPL, offer, $100.00, so the trader
// buys with SW[12:11] = 00 and k >= 400 (SW[10:2] = 1 1001 0000 or higher,
// e.g. all on). k = 399 ($99.90) gives no trade: the exchange times out.
//
// Trader LEDs
//   LED9   buy (stretched to about 50 ms)
//   LED10  no trade: valid market data, rule says no (stretched)
//   LED11  the trader received a frame that is not market data (since BTNU)
//   LED13  trader CRS_DV activity (receive)

module one_board_top #(
  parameter bit SPECULATIVE_TX = 1'b0,
  parameter int RUN_LEN        = 4096,
  parameter int BAUD           = 115200
) (
  // Exchange's LAN8720 on JB
  input  logic        ex_ref_clk,  // JB[0]
  input  logic        ex_crs_dv,   // JB[1]
  input  logic [1:0]  ex_rxd,      // JB[3:2]
  output logic        ex_tx_en,    // JB[4]
  output logic [1:0]  ex_txd,      // JB[6:5]

  // Trader's LAN8720 on JC
  input  logic        tr_ref_clk,  // JC[0]
  input  logic        tr_crs_dv,   // JC[1]
  input  logic [1:0]  tr_rxd,      // JC[3:2]
  output logic        tr_tx_en,    // JC[4]
  output logic [1:0]  tr_txd,      // JC[6:5]

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

  localparam logic [31:0] LIMIT_BASE = 32'd600_000;  // $60.00
  localparam logic [31:0] LIMIT_STEP = 32'd1_000;    // $0.10

  // ---------------------------------------------------------------- exchange

  logic [15:0] ex_led;
  logic [6:0]  ex_seg;
  logic        ex_dp;
  logic [3:0]  ex_an;

  exchange #(.RUN_LEN(RUN_LEN), .BAUD(BAUD)) u_ex (
    .rmii_ref_clk (ex_ref_clk),
    .rmii_crs_dv  (ex_crs_dv),
    .rmii_rxd     (ex_rxd),
    .rmii_tx_en   (ex_tx_en),
    .rmii_txd     (ex_txd),
    .btnC         (btnC),
    .btnU         (btnU),
    .btnD         (btnD),
    .btnR         (btnR),
    .rs_tx        (rs_tx),
    .sw           (sw),
    .led          (ex_led),
    .seg          (ex_seg),
    .dp           (ex_dp),
    .an           (ex_an)
  );

  // ---------------------------------------------------------------- trader clock, reset

  logic clk;

  BUFG u_bufg (.I(tr_ref_clk), .O(clk));

  logic [4:0] por = '1;
  logic       rst = 1'b1;

  always_ff @(posedge clk) begin
    if (por != 0)
      por <= por - 5'd1;
    rst <= (por != 0);
  end

  // ---------------------------------------------------------------- trader inputs

  logic        clear, show_limit;
  logic [15:0] sw_s;

  debounce u_db_u (.clk(clk), .rst(rst), .btn_async(btnU), .level(),           .rise(clear));
  debounce u_db_l (.clk(clk), .rst(rst), .btn_async(btnL), .level(show_limit), .rise());

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

  logic        buy, no_trade, rx_crs;
  logic [31:0] n_ignored;

  trader_core #(
    .SPECULATIVE_TX (SPECULATIVE_TX),
    .LIMIT_BASE     (LIMIT_BASE),
    .LIMIT_STEP     (LIMIT_STEP)
  ) u_tr (
    .clk         (clk),
    .rst         (rst),
    .sel         (sw_s[12:11]),
    .k           ({3'b000, sw_s[10:2]}),
    .clear       (clear),
    .rmii_crs_dv (tr_crs_dv),
    .rmii_rxd    (tr_rxd),
    .rmii_tx_en  (tr_tx_en),
    .rmii_txd    (tr_txd),
    .limit       (),
    .buy         (buy),
    .no_trade    (no_trade),
    .n_md        (),
    .n_buys      (),
    .n_ignored   (n_ignored),
    .n_sent      (),
    .n_cut       (),
    .rx_crs      (rx_crs),
    .tx_active   ()
  );

  // ---------------------------------------------------------------- trader limit display

  // Limit in cents, from the switches. XX.XX below 10000 cents, else
  // cents / 10 as XXX.X; x / 10 = (x * 838861) >> 23, exact below 4,000,000.
  localparam logic [19:0] DIV10_K = 20'd838861;

  logic [31:0] cents;
  logic [42:0] dimes_prod;
  logic [13:0] lim_val;
  logic [3:0]  lim_dp;
  logic [6:0]  tr_seg;
  logic        tr_dp;
  logic [3:0]  tr_an;

  always_ff @(posedge clk) begin
    cents      <= LIMIT_BASE / 100 + 32'(sw_s[10:2]) * (LIMIT_STEP / 100);
    dimes_prod <= cents[22:0] * DIV10_K;
    if (cents < 32'd10_000) begin
      lim_val <= cents[13:0];
      lim_dp  <= 4'b0100;
    end else begin
      lim_val <= dimes_prod[36:23];
      lim_dp  <= 4'b0010;
    end
  end

  sevenseg u_seg (
    .clk     (clk),
    .rst     (rst),
    .value   (lim_val),
    .blank   (1'b0),
    .dp_mask (lim_dp),
    .seg     (tr_seg),
    .dp      (tr_dp),
    .an      (tr_an)
  );

  // ---------------------------------------------------------------- trader LEDs

  localparam int STRETCH = 2_500_000;  // about 50 ms
  logic [21:0] buy_cnt, nt_cnt, rx_led_cnt;
  logic [15:0] tr_led;

  always_ff @(posedge clk) begin
    if (rst) begin
      buy_cnt    <= '0;
      nt_cnt     <= '0;
      rx_led_cnt <= '0;
    end else begin
      if (buy)                  buy_cnt <= 22'(STRETCH);
      else if (buy_cnt != 0)    buy_cnt <= buy_cnt - 22'd1;
      if (no_trade)             nt_cnt <= 22'(STRETCH);
      else if (nt_cnt != 0)     nt_cnt <= nt_cnt - 22'd1;
      if (rx_crs)               rx_led_cnt <= 22'(STRETCH);
      else if (rx_led_cnt != 0) rx_led_cnt <= rx_led_cnt - 22'd1;
    end
  end

  always_ff @(posedge clk) begin
    tr_led     <= '0;
    tr_led[9]  <= (buy_cnt != 0);
    tr_led[10] <= (nt_cnt != 0);
    tr_led[11] <= (n_ignored != 0);
    tr_led[13] <= (rx_led_cnt != 0);
  end

  // ---------------------------------------------------------------- shared outputs

  // The exchange leaves LED9-11 and LED13 off. Both sides are registered in
  // their own domain; the pins are slow, so the mixing is combinational.
  assign led = ex_led | tr_led;
  assign seg = show_limit ? tr_seg : ex_seg;
  assign dp  = show_limit ? tr_dp  : ex_dp;
  assign an  = show_limit ? tr_an  : ex_an;

endmodule
