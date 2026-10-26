`timescale 1ns / 1ps
// Board 1: exchange + fair source. JB = FPGA sniper, JA = PC market maker.
// Clock is the 50 MHz REF_CLK from the JB LAN8720. Do not use JA[0] as a
// second clock; both PHYs must share this 50 MHz.
//
// BTNC start   BTNU abort   BTNR UART dump (115200 8N1)
// 7-seg: fair in dollars. LED0 run  LED1 quotes up  LED2 F sniped
// LED3 P too late  LED4/5 F rx/tx  LED6/7 P rx/tx  LED15 done

module exchange_latarb_top #(
  parameter int BAUD = 115200
) (
  input  logic        rmii_f_ref_clk,
  input  logic        rmii_f_crs_dv,
  input  logic [1:0]  rmii_f_rxd,
  output logic        rmii_f_tx_en,
  output logic [1:0]  rmii_f_txd,

  input  logic        rmii_p_crs_dv,
  input  logic [1:0]  rmii_p_rxd,
  output logic        rmii_p_tx_en,
  output logic [1:0]  rmii_p_txd,

  input  logic        btnC, btnU, btnR,
  output logic        rs_tx,
  input  logic [15:0] sw,
  output logic [15:0] led,
  output logic [6:0]  seg,
  output logic        dp,
  output logic [3:0]  an
);

  logic clk;
  BUFG u_bufg (.I(rmii_f_ref_clk), .O(clk));

  logic [4:0] por = '1;
  logic       rst = 1'b1;
  always_ff @(posedge clk) begin
    if (por != 0) por <= por - 5'd1;
    rst <= (por != 0);
  end

  logic start, abort, dump_start;
  debounce u_c (.clk, .rst, .btn_async(btnC), .level(), .rise(start));
  debounce u_u (.clk, .rst, .btn_async(btnU), .level(), .rise(abort));
  debounce u_r (.clk, .rst, .btn_async(btnR), .level(), .rise(dump_start));

  logic        run_active, run_done, quotes_up, snipe_seen, late_seen;
  logic        rx_f, rx_p, tx_f, tx_p, dump_busy;
  logic [31:0] fv_now;
  logic signed [31:0] pnl_f, pnl_p;
  logic [4:0]  log_addr, log_n;
  logic [31:0] log_fv, log_fill, log_pnl_f, log_pnl_p;
  logic [7:0]  log_flags;

  exchange_latarb u_core (
    .clk, .rst, .start, .abort, .dump_hold(dump_busy),
    .rmii_f_crs_dv, .rmii_f_rxd, .rmii_f_tx_en, .rmii_f_txd,
    .rmii_p_crs_dv, .rmii_p_rxd, .rmii_p_tx_en, .rmii_p_txd,
    .run_active, .run_done, .quotes_up, .snipe_seen, .late_seen,
    .rx_f, .rx_p, .tx_f, .tx_p, .fv_now, .pnl_f, .pnl_p,
    .log_addr, .log_fv, .log_fill_px(log_fill),
    .log_pnl_f, .log_pnl_p, .log_flags, .log_n
  );

  event_dump #(.CLK_HZ(50_000_000), .BAUD(BAUD)) u_dump (
    .clk, .rst, .start(dump_start), .n(log_n),
    .rd_addr(log_addr), .rd_fv(log_fv), .rd_fill(log_fill),
    .rd_pnl_f(log_pnl_f), .rd_pnl_p(log_pnl_p), .rd_flags(log_flags),
    .tx(rs_tx), .busy(dump_busy)
  );

  logic [13:0] disp_val;
  always_ff @(posedge clk) begin
    if (fv_now > 32'd999900) disp_val <= 14'd9999;
    else disp_val <= fv_now[13:0] / 14'd100;
  end

  sevenseg u_seg (
    .clk, .rst, .value(disp_val), .blank(!run_active && !run_done),
    .dp_mask(4'b0000), .seg, .dp, .an
  );

  localparam int STRETCH = 2_500_000;
  logic [21:0] rf, tf, rp, tp;
  always_ff @(posedge clk) begin
    if (rst) begin
      rf <= '0; tf <= '0; rp <= '0; tp <= '0;
    end else begin
      if (rx_f) rf <= 22'(STRETCH); else if (rf != 0) rf <= rf - 22'd1;
      if (tx_f) tf <= 22'(STRETCH); else if (tf != 0) tf <= tf - 22'd1;
      if (rx_p) rp <= 22'(STRETCH); else if (rp != 0) rp <= rp - 22'd1;
      if (tx_p) tp <= 22'(STRETCH); else if (tp != 0) tp <= tp - 22'd1;
    end
  end

  always_ff @(posedge clk) begin
    led <= '0;
    led[0]  <= run_active;
    led[1]  <= quotes_up;
    led[2]  <= snipe_seen;
    led[3]  <= late_seen;
    led[4]  <= (rf != 0);
    led[5]  <= (tf != 0);
    led[6]  <= (rp != 0);
    led[7]  <= (tp != 0);
    led[8]  <= dump_busy;
    led[15] <= run_done;
  end

endmodule
