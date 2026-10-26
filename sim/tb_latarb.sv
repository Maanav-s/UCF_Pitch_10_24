`timescale 1ns / 1ps
// End-to-end sim of exchange_latarb + trader_sniper + a PC market maker.
// DELAY_DIV=50_000 so a 1 s fair wait is 1000 clocks.
//
// 1. Opening fair $100.00. MM quotes 9999 / 10001. quotes_up.
// 2. First jump to $100.83. F buys the stale ask 10001. P cancel too late.
// 3. MM requotes around 10083. F sells the new bid and flattens.
// 4. Run continues; at least one snipe is recorded.
//
// Prints TB_LATARB PASS or TB_LATARB FAIL.

module tb_latarb;
  import lat_arb_pkg::*;

  localparam real CLK_PERIOD = 20.0;
  localparam int  DIV        = 50_000;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #(CLK_PERIOD / 2) clk = ~clk;

  logic start = 1'b0, abort = 1'b0;

  logic        f_en, p_en, t_en, mm_en;
  logic [1:0]  f_td, p_td, t_td, mm_td;
  wire         p_en_mm = mm_en;
  wire  [1:0]  p_td_mm = mm_td;

  logic run_active, run_done, quotes_up, snipe_seen, late_seen;
  logic rx_f, rx_p, tx_f, tx_p;
  logic [31:0] fv_now;
  logic signed [31:0] pnl_f, pnl_p;
  logic [4:0] log_addr = '0, log_n;
  logic [31:0] log_fv, log_fill, log_pnl_f, log_pnl_p;
  logic [7:0]  log_flags;

  exchange_latarb #(.DELAY_DIV(DIV), .QUOTE_TO(10)) dut (
    .clk, .rst, .start, .abort, .dump_hold(1'b0),
    .rmii_f_crs_dv(t_en), .rmii_f_rxd(t_td),
    .rmii_f_tx_en(f_en), .rmii_f_txd(f_td),
    .rmii_p_crs_dv(p_en_mm), .rmii_p_rxd(p_td_mm),
    .rmii_p_tx_en(p_en), .rmii_p_txd(p_td),
    .run_active, .run_done, .quotes_up, .snipe_seen, .late_seen,
    .rx_f, .rx_p, .tx_f, .tx_p, .fv_now, .pnl_f, .pnl_p,
    .log_addr, .log_fv, .log_fill_px(log_fill),
    .log_pnl_f, .log_pnl_p, .log_flags, .log_n
  );

  trader_sniper #(.DELAY_DIV(DIV)) u_f (
    .clk, .rst, .delay_ms(8'd0),
    .rmii_crs_dv(f_en), .rmii_rxd(f_td),
    .rmii_tx_en(t_en), .rmii_txd(t_td),
    .sniping(), .flattening(), .last_fill(), .pos(), .rx_act(), .tx_act()
  );

  // ---------------------------------------------------------------- PC MM

  logic        mm_send, mm_busy, mm_got, mm_crs;
  logic [5:0]  mm_plen, mm_rlen;
  logic [7:0]  mm_pay [0:MAX_PAY-1];
  logic [7:0]  mm_rpay [0:MAX_PAY-1];

  pkt_tx u_mmtx (
    .clk, .rst, .send(mm_send),
    .dst_mac(E_MAC), .dst_ip(E_IP),
    .src_mac(P_MAC), .src_ip(P_IP),
    .pay_len(mm_plen), .pay(mm_pay), .busy(mm_busy),
    .rmii_tx_en(mm_en), .rmii_txd(mm_td)
  );
  pkt_rx u_mmrx (
    .clk, .rst, .rmii_crs_dv(p_en), .rmii_rxd(p_td),
    .our_mac(P_MAC), .our_ip(P_IP),
    .pkt_valid(mm_got), .pay_len(mm_rlen), .pay(mm_rpay), .rx_crs(mm_crs)
  );

  typedef enum logic [2:0] {M_IDLE, M_C1, M_C2, M_Q1, M_Q2} mm_t;
  mm_t         mmst;
  logic [31:0] mm_fv, bid_oid, ask_oid, next_oid;
  logic [15:0] mm_seq;
  logic        have_q, need_q;

  task automatic mm_hdr(input logic [7:0] typ);
    mm_pay[0] = typ; mm_pay[1] = SRC_P;
    mm_pay[2] = mm_seq[15:8]; mm_pay[3] = mm_seq[7:0];
  endtask

  always_ff @(posedge clk) begin
    mm_send <= 1'b0;
    if (rst) begin
      mmst <= M_IDLE; have_q <= 1'b0; need_q <= 1'b0;
      next_oid <= 32'd1; mm_seq <= '0; bid_oid <= '0; ask_oid <= '0;
    end else begin
      if (mm_got && mm_rpay[0] == T_FAIR) begin
        mm_fv  <= {mm_rpay[6], mm_rpay[7], mm_rpay[8], mm_rpay[9]};
        need_q <= 1'b1;
        if (have_q) mmst <= M_C1;
        else        mmst <= M_Q1;
      end else if (!mm_busy && !mm_send) begin
        unique case (mmst)
          M_C1: begin
            mm_hdr(T_CANCEL);
            {mm_pay[4],mm_pay[5],mm_pay[6],mm_pay[7]} <= bid_oid;
            mm_plen <= 6'(LEN_CANCEL);
            mm_send <= 1'b1; mm_seq <= mm_seq + 16'd1;
            mmst <= M_C2;
          end
          M_C2: begin
            mm_hdr(T_CANCEL);
            {mm_pay[4],mm_pay[5],mm_pay[6],mm_pay[7]} <= ask_oid;
            mm_plen <= 6'(LEN_CANCEL);
            mm_send <= 1'b1; mm_seq <= mm_seq + 16'd1;
            have_q <= 1'b0; mmst <= M_Q1;
          end
          M_Q1: begin
            mm_hdr(T_ORDER);
            bid_oid <= next_oid;
            {mm_pay[4],mm_pay[5],mm_pay[6],mm_pay[7]} <= next_oid;
            mm_pay[8] <= SIDE_B; mm_pay[9] <= TIF_REST;
            {mm_pay[10],mm_pay[11],mm_pay[12],mm_pay[13]} <= mm_fv - 32'(HALF_SP);
            {mm_pay[14],mm_pay[15]} <= QUOTE_SZ;
            mm_plen <= 6'(LEN_ORDER);
            mm_send <= 1'b1; mm_seq <= mm_seq + 16'd1;
            next_oid <= next_oid + 32'd2;
            mmst <= M_Q2;
          end
          M_Q2: begin
            mm_hdr(T_ORDER);
            ask_oid <= next_oid;
            {mm_pay[4],mm_pay[5],mm_pay[6],mm_pay[7]} <= next_oid;
            mm_pay[8] <= SIDE_S; mm_pay[9] <= TIF_REST;
            {mm_pay[10],mm_pay[11],mm_pay[12],mm_pay[13]} <= mm_fv + 32'(HALF_SP);
            {mm_pay[14],mm_pay[15]} <= QUOTE_SZ;
            mm_plen <= 6'(LEN_ORDER);
            mm_send <= 1'b1; mm_seq <= mm_seq + 16'd1;
            next_oid <= next_oid + 32'd2;
            have_q <= 1'b1; need_q <= 1'b0; mmst <= M_IDLE;
          end
          default: ;
        endcase
      end
    end
  end

  int errors = 0;
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      $display("ERROR %0t: %s", $time, msg);
      errors++;
    end
  endtask

  initial begin
    repeat (8) @(posedge clk);
    rst = 1'b0;
    repeat (8) @(posedge clk);

    $display("Start run");
    @(negedge clk); start = 1'b1;
    @(negedge clk); start = 1'b0;

    wait (quotes_up);
    $display("quotes up fv=%0d", fv_now);
    check(fv_now == 32'd10000, "opening fair is not 10000");

    wait (snipe_seen);
    $display("snipe fv=%0d fill=%0d late=%0b", fv_now, log_fill, late_seen);
    check(fv_now == 32'd10083, "first jump is not 10083");
    check(late_seen, "expected P cancel too late after the snipe");

    repeat (50_000) @(posedge clk);
    check(snipe_seen, "no snipe recorded");
    $display("pnl F=%0d P=%0d n=%0d", pnl_f, pnl_p, log_n);

    if (errors == 0) $display("TB_LATARB PASS");
    else             $display("TB_LATARB FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("TB_LATARB FAIL (timeout) quotes=%0b snipe=%0b fv=%0d",
             quotes_up, snipe_seen, fv_now);
    $finish;
  end

endmodule
