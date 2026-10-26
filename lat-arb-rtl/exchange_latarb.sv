`timescale 1ns / 1ps
// Exchange + fair source. JB-side PHY talks to the FPGA sniper (F),
// JA-side PHY talks to the PC market maker (P). One 50 MHz clock from
// the JB module. BTNC starts the hardcoded fair path; F and P both see
// each FAIR. BOOK is sent when a rest lands in an empty slot.

module exchange_latarb
  import lat_arb_pkg::*;
#(
  parameter int  DELAY_DIV  = 1,       // 50_000 in simulation
  parameter int  QUOTE_TO   = 10,      // seconds to wait for first quotes
  parameter bit  TX_NEGEDGE = 1'b0
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  logic        abort,
  input  logic        dump_hold,

  input  logic        rmii_f_crs_dv,
  input  logic [1:0]  rmii_f_rxd,
  output logic        rmii_f_tx_en,
  output logic [1:0]  rmii_f_txd,

  input  logic        rmii_p_crs_dv,
  input  logic [1:0]  rmii_p_rxd,
  output logic        rmii_p_tx_en,
  output logic [1:0]  rmii_p_txd,

  output logic        run_active,
  output logic        run_done,
  output logic        quotes_up,
  output logic        snipe_seen,
  output logic        late_seen,
  output logic        rx_f, rx_p, tx_f, tx_p,
  output logic [31:0] fv_now,
  output logic signed [31:0] pnl_f, pnl_p,

  input  logic [4:0]  log_addr,
  output logic [31:0] log_fv,
  output logic [31:0] log_fill_px,
  output logic [31:0] log_pnl_f,
  output logic [31:0] log_pnl_p,
  output logic [7:0]  log_flags,   // [0] snipe [1] late
  output logic [4:0]  log_n
);

  // ---------------------------------------------------------------- PHYs

  logic        f_send, p_send, f_busy, p_busy;
  logic [47:0] f_dmac, p_dmac;
  logic [31:0] f_dip, p_dip;
  logic [5:0]  f_plen, p_plen;
  logic [7:0]  f_pay [0:MAX_PAY-1];
  logic [7:0]  p_pay [0:MAX_PAY-1];
  logic        f_crs, p_crs;

  pkt_tx #(.TX_NEGEDGE(TX_NEGEDGE)) u_ftx (
    .clk, .rst, .send(f_send),
    .dst_mac(f_dmac), .dst_ip(f_dip),
    .src_mac(E_MAC), .src_ip(E_IP),
    .pay_len(f_plen), .pay(f_pay), .busy(f_busy),
    .rmii_tx_en(rmii_f_tx_en), .rmii_txd(rmii_f_txd)
  );
  pkt_tx #(.TX_NEGEDGE(TX_NEGEDGE)) u_ptx (
    .clk, .rst, .send(p_send),
    .dst_mac(p_dmac), .dst_ip(p_dip),
    .src_mac(E_MAC), .src_ip(E_IP),
    .pay_len(p_plen), .pay(p_pay), .busy(p_busy),
    .rmii_tx_en(rmii_p_tx_en), .rmii_txd(rmii_p_txd)
  );

  logic        f_got, p_got;
  logic [5:0]  f_rlen, p_rlen;
  logic [7:0]  f_rpay [0:MAX_PAY-1];
  logic [7:0]  p_rpay [0:MAX_PAY-1];

  pkt_rx u_frx (
    .clk, .rst, .rmii_crs_dv(rmii_f_crs_dv), .rmii_rxd(rmii_f_rxd),
    .our_mac(E_MAC), .our_ip(E_IP),
    .pkt_valid(f_got), .pay_len(f_rlen), .pay(f_rpay), .rx_crs(f_crs)
  );
  pkt_rx u_prx (
    .clk, .rst, .rmii_crs_dv(rmii_p_crs_dv), .rmii_rxd(rmii_p_rxd),
    .our_mac(E_MAC), .our_ip(E_IP),
    .pkt_valid(p_got), .pay_len(p_rlen), .pay(p_rpay), .rx_crs(p_crs)
  );

  assign rx_f = f_crs;
  assign rx_p = p_crs;
  assign tx_f = f_busy;
  assign tx_p = p_busy;

  // ---------------------------------------------------------------- inbound FIFOs

  localparam int QN = 4;
  logic [7:0] qf [0:QN-1][0:MAX_PAY-1];
  logic [7:0] qp [0:QN-1][0:MAX_PAY-1];
  logic [5:0] qf_l [0:QN-1], qp_l [0:QN-1];
  logic [1:0] qf_w, qf_r, qp_w, qp_r;
  logic [2:0] qf_n, qp_n;
  wire        f_push = f_got && (qf_n != 3'(QN));
  wire        p_push = p_got && (qp_n != 3'(QN));

  // ---------------------------------------------------------------- book

  logic        cmd_valid;
  logic [7:0]  cmd_type, cmd_src, cmd_side, cmd_tif;
  logic [31:0] cmd_oid, cmd_px;
  logic [15:0] cmd_sz;
  logic        ack_valid, fill_valid, book_upd;
  logic [7:0]  ack_status, ack_src, fill_src_aggr, fill_src_rest, fill_side;
  logic [31:0] ack_oid, fill_oid_aggr, fill_oid_rest, fill_px;
  logic [15:0] fill_sz;
  logic        bid_v, ask_v;
  logic [31:0] bid_oid, bid_px, ask_oid, ask_px;
  logic [15:0] bid_sz, ask_sz;
  logic [7:0]  bid_owner, ask_owner;
  logic signed [15:0] pos_f, pos_p;
  logic signed [31:0] cash_f, cash_p;
  logic        book_clear;

  book_match u_book (
    .clk, .rst, .clear(book_clear),
    .cmd_valid, .cmd_type, .cmd_src, .cmd_oid, .cmd_side, .cmd_tif, .cmd_px, .cmd_sz,
    .ack_valid, .ack_status, .ack_oid, .ack_src,
    .fill_valid, .fill_oid_aggr, .fill_oid_rest, .fill_src_aggr, .fill_src_rest,
    .fill_px, .fill_sz, .fill_side,
    .book_upd, .bid_v, .bid_oid, .bid_px, .bid_sz, .bid_owner,
    .ask_v, .ask_oid, .ask_px, .ask_sz, .ask_owner,
    .pos_f, .pos_p, .cash_f, .cash_p
  );

  assign quotes_up = bid_v && ask_v;
  assign pnl_f = cash_f + pos_f * $signed(fv_now);
  assign pnl_p = cash_p + pos_p * $signed(fv_now);

  // ---------------------------------------------------------------- time, fair FSM, sequencer

  logic [63:0] tcnt;
  always_ff @(posedge clk) begin
    if (rst) tcnt <= '0;
    else     tcnt <= tcnt + 64'd1;
  end

  typedef enum logic [3:0] {
    S_IDLE, S_POP, S_ISSUE, S_HOLD,
    S_ACK, S_FILL_AG, S_FILL_RE, S_BOOK_F, S_BOOK_P,
    S_FAIR_F, S_FAIR_P
  } st_t;

  typedef enum logic [2:0] {R_IDLE, R_INIT, R_WAITQ, R_WAITD, R_JUMP, R_DONE} run_t;

  st_t  st;
  run_t run;
  logic [4:0]  fair_i;
  logic [31:0] dly;
  logic [15:0] seq_f, seq_p;
  logic        take_f;          // pop from F (else P)
  logic [7:0]  cur [0:MAX_PAY-1];
  logic [5:0]  cur_len;
  logic        cap_ack, cap_fill, cap_book, cap_late, cap_snipe;
  logic [7:0]  c_ack_st, c_ack_src, c_fside, c_fag, c_frs;
  logic [31:0] c_ack_oid, c_fill_px, c_oid_ag, c_oid_rs;
  logic [15:0] c_fill_sz;
  logic        want_fair;
  wire         f_pop = (st == S_IDLE) && !want_fair && (qf_n != 0);
  wire         p_pop = (st == S_IDLE) && !want_fair && !f_pop && (qp_n != 0);
  logic [31:0] fv;
  logic        snipe_seen_r, late_seen_r;
  logic [31:0] rec_fv      [0:N_FAIR-1];
  logic [31:0] rec_fill    [0:N_FAIR-1];
  logic [31:0] rec_pnl_f   [0:N_FAIR-1];
  logic [31:0] rec_pnl_p   [0:N_FAIR-1];
  logic [7:0]  rec_flags   [0:N_FAIR-1];
  logic [4:0]  rec_n;
  logic        round_snipe, round_late;
  logic [31:0] round_fill;

  assign fv_now     = fv;
  assign run_active = (run != R_IDLE && run != R_DONE);
  assign run_done   = (run == R_DONE);
  assign snipe_seen = snipe_seen_r;
  assign late_seen  = late_seen_r;
  assign log_n      = rec_n;
  assign log_fv      = rec_fv[log_addr];
  assign log_fill_px = rec_fill[log_addr];
  assign log_pnl_f   = rec_pnl_f[log_addr];
  assign log_pnl_p   = rec_pnl_p[log_addr];
  assign log_flags   = rec_flags[log_addr];

  task automatic hdr(inout logic [7:0] b [0:MAX_PAY-1],
                     input logic [7:0] typ, input logic [15:0] seq);
    b[0] = typ; b[1] = SRC_E; b[2] = seq[15:8]; b[3] = seq[7:0];
  endtask

  always_ff @(posedge clk) begin
    cmd_valid   <= 1'b0;
    book_clear  <= 1'b0;
    f_send      <= 1'b0;
    p_send      <= 1'b0;
    if (rst) begin
      st <= S_IDLE; run <= R_IDLE;
      fair_i <= '0; dly <= '0; seq_f <= '0; seq_p <= '0;
      fv <= FAIR_PX[0];
      rec_n <= '0;
      snipe_seen_r <= 1'b0; late_seen_r <= 1'b0;
      round_snipe <= 1'b0; round_late <= 1'b0; round_fill <= '0;
      want_fair <= 1'b0;
      qf_w <= '0; qf_r <= '0; qf_n <= '0;
      qp_w <= '0; qp_r <= '0; qp_n <= '0;
    end else if (abort) begin
      st <= S_IDLE; run <= R_IDLE;
      want_fair <= 1'b0;
      rec_n <= '0;
      qf_w <= '0; qf_r <= '0; qf_n <= '0;
      qp_w <= '0; qp_r <= '0; qp_n <= '0;
    end else begin
      if (f_push) begin
        qf[qf_w]   <= f_rpay;
        qf_l[qf_w] <= f_rlen;
        qf_w       <= qf_w + 2'd1;
      end
      if (p_push) begin
        qp[qp_w]   <= p_rpay;
        qp_l[qp_w] <= p_rlen;
        qp_w       <= qp_w + 2'd1;
      end
      qf_n <= qf_n + (f_push ? 3'd1 : 3'd0) - (f_pop ? 3'd1 : 3'd0);
      qp_n <= qp_n + (p_push ? 3'd1 : 3'd0) - (p_pop ? 3'd1 : 3'd0);

      rec_pnl_f[fair_i] <= pnl_f;
      rec_pnl_p[fair_i] <= pnl_p;

      unique case (run)
        R_IDLE:
          if (start && !dump_hold) begin
            book_clear <= 1'b1;
            fair_i <= '0;
            fv <= FAIR_PX[0];
            rec_n <= '0;
            round_snipe <= 1'b0; round_late <= 1'b0; round_fill <= '0;
            snipe_seen_r <= 1'b0; late_seen_r <= 1'b0;
            want_fair <= 1'b1;
            run <= R_INIT;
          end
        R_INIT:
          if (!want_fair) begin
            dly <= 32'(QUOTE_TO) * 32'(CLK_HZ) / 32'(DELAY_DIV == 0 ? 1 : DELAY_DIV);
            run <= R_WAITQ;
          end
        R_WAITQ:
          if (bid_v && ask_v) begin
            fair_i <= 5'd1;
            dly <= fair_clks(DELAY_DIV, 1);
            run <= R_WAITD;
          end else if (dly == 0) begin
            run <= R_DONE;
          end else begin
            dly <= dly - 32'd1;
          end
        R_WAITD:
          if (dly == 0) begin
            fv <= FAIR_PX[fair_i];
            want_fair <= 1'b1;
            run <= R_JUMP;
          end else begin
            dly <= dly - 32'd1;
          end
        R_JUMP:
          if (!want_fair) begin
            if (fair_i == 5'(N_FAIR - 1))
              run <= R_DONE;
            else begin
              fair_i <= fair_i + 5'd1;
              dly <= fair_clks(DELAY_DIV, fair_i + 1);
              run <= R_WAITD;
            end
          end
        R_DONE: ;
        default: ;
      endcase

      unique case (st)
        S_IDLE: begin
          if (want_fair) begin
            rec_fv[fair_i]    <= fv;
            rec_fill[fair_i]  <= '0;
            rec_flags[fair_i] <= '0;
            rec_n             <= fair_i + 5'd1;
            st <= S_FAIR_F;
          end else if (qf_n != 0) begin
            take_f  <= 1'b1;
            cur     <= qf[qf_r];
            cur_len <= qf_l[qf_r];
            qf_r    <= qf_r + 2'd1;
            st      <= S_POP;
          end else if (qp_n != 0) begin
            take_f  <= 1'b0;
            cur     <= qp[qp_r];
            cur_len <= qp_l[qp_r];
            qp_r    <= qp_r + 2'd1;
            st      <= S_POP;
          end
        end

        S_POP: begin
          cmd_type <= cur[0];
          cmd_src  <= cur[1];
          cmd_oid  <= {cur[4], cur[5], cur[6], cur[7]};
          cmd_side <= cur[8];
          cmd_tif  <= cur[9];
          cmd_px   <= {cur[10], cur[11], cur[12], cur[13]};
          cmd_sz   <= {cur[14], cur[15]};
          if (cur[0] == T_CANCEL) begin
            cmd_type <= T_CANCEL;
            cmd_oid  <= {cur[4], cur[5], cur[6], cur[7]};
          end
          cmd_valid <= (cur[0] == T_ORDER || cur[0] == T_CANCEL);
          st <= (cur[0] == T_ORDER || cur[0] == T_CANCEL) ? S_ISSUE : S_IDLE;
        end

        S_ISSUE: st <= S_HOLD;

        S_HOLD: begin
          cap_ack  <= ack_valid;
          cap_fill <= fill_valid;
          cap_book <= book_upd;
          c_ack_st <= ack_status;
          c_ack_src<= ack_src;
          c_ack_oid<= ack_oid;
          c_fill_px<= fill_px;
          c_fill_sz<= fill_sz;
          c_fside  <= fill_side;
          c_fag    <= fill_src_aggr;
          c_frs    <= fill_src_rest;
          c_oid_ag <= fill_oid_aggr;
          c_oid_rs <= fill_oid_rest;
          if (fill_valid && fill_src_aggr == SRC_F) begin
            cap_snipe          <= 1'b1;
            round_snipe        <= 1'b1;
            round_fill         <= fill_px;
            rec_fill[fair_i]   <= fill_px;
            rec_flags[fair_i]  <= rec_flags[fair_i] | 8'h01;
            snipe_seen_r       <= 1'b1;
          end
          if (ack_valid && ack_status == ACK_CANCEL_TOO_LATE) begin
            cap_late           <= 1'b1;
            round_late         <= 1'b1;
            rec_flags[fair_i]  <= rec_flags[fair_i] | 8'h02;
            late_seen_r        <= 1'b1;
          end
          st <= ack_valid ? S_ACK : S_IDLE;
        end

        S_ACK: begin
          if (c_ack_src == SRC_F) begin
            if (!f_busy) begin
              hdr(f_pay, T_ACK, seq_f);
              f_pay[4] <= c_ack_oid[31:24]; f_pay[5] <= c_ack_oid[23:16];
              f_pay[6] <= c_ack_oid[15:8];  f_pay[7] <= c_ack_oid[7:0];
              f_pay[8] <= c_ack_st;
              f_plen <= 6'(LEN_ACK); f_dmac <= F_MAC; f_dip <= F_IP;
              f_send <= 1'b1; seq_f <= seq_f + 16'd1;
              st <= cap_fill ? S_FILL_AG : (cap_book ? S_BOOK_F : S_IDLE);
            end
          end else begin
            if (!p_busy) begin
              hdr(p_pay, T_ACK, seq_p);
              p_pay[4] <= c_ack_oid[31:24]; p_pay[5] <= c_ack_oid[23:16];
              p_pay[6] <= c_ack_oid[15:8];  p_pay[7] <= c_ack_oid[7:0];
              p_pay[8] <= c_ack_st;
              p_plen <= 6'(LEN_ACK); p_dmac <= P_MAC; p_dip <= P_IP;
              p_send <= 1'b1; seq_p <= seq_p + 16'd1;
              st <= cap_fill ? S_FILL_AG : (cap_book ? S_BOOK_F : S_IDLE);
            end
          end
        end

        S_FILL_AG: begin
          if (c_fag == SRC_F) begin
            if (!f_busy) begin
              hdr(f_pay, T_FILL, seq_f);
              f_pay[4] <= c_oid_ag[31:24]; f_pay[5] <= c_oid_ag[23:16];
              f_pay[6] <= c_oid_ag[15:8];  f_pay[7] <= c_oid_ag[7:0];
              f_pay[8] <= c_fill_px[31:24]; f_pay[9] <= c_fill_px[23:16];
              f_pay[10]<= c_fill_px[15:8];  f_pay[11]<= c_fill_px[7:0];
              f_pay[12]<= c_fill_sz[15:8];  f_pay[13]<= c_fill_sz[7:0];
              {f_pay[14],f_pay[15],f_pay[16],f_pay[17],
               f_pay[18],f_pay[19],f_pay[20],f_pay[21]} <= tcnt;
              f_plen <= 6'(LEN_FILL); f_dmac <= F_MAC; f_dip <= F_IP;
              f_send <= 1'b1; seq_f <= seq_f + 16'd1;
              st <= S_FILL_RE;
            end
          end else if (!p_busy) begin
            hdr(p_pay, T_FILL, seq_p);
            p_pay[4] <= c_oid_ag[31:24]; p_pay[5] <= c_oid_ag[23:16];
            p_pay[6] <= c_oid_ag[15:8];  p_pay[7] <= c_oid_ag[7:0];
            p_pay[8] <= c_fill_px[31:24]; p_pay[9] <= c_fill_px[23:16];
            p_pay[10]<= c_fill_px[15:8];  p_pay[11]<= c_fill_px[7:0];
            p_pay[12]<= c_fill_sz[15:8];  p_pay[13]<= c_fill_sz[7:0];
            {p_pay[14],p_pay[15],p_pay[16],p_pay[17],
             p_pay[18],p_pay[19],p_pay[20],p_pay[21]} <= tcnt;
            p_plen <= 6'(LEN_FILL); p_dmac <= P_MAC; p_dip <= P_IP;
            p_send <= 1'b1; seq_p <= seq_p + 16'd1;
            st <= S_FILL_RE;
          end
        end

        S_FILL_RE: begin
          if (c_frs == SRC_F) begin
            if (!f_busy) begin
              hdr(f_pay, T_FILL, seq_f);
              f_pay[4] <= c_oid_rs[31:24]; f_pay[5] <= c_oid_rs[23:16];
              f_pay[6] <= c_oid_rs[15:8];  f_pay[7] <= c_oid_rs[7:0];
              f_pay[8] <= c_fill_px[31:24]; f_pay[9] <= c_fill_px[23:16];
              f_pay[10]<= c_fill_px[15:8];  f_pay[11]<= c_fill_px[7:0];
              f_pay[12]<= c_fill_sz[15:8];  f_pay[13]<= c_fill_sz[7:0];
              {f_pay[14],f_pay[15],f_pay[16],f_pay[17],
               f_pay[18],f_pay[19],f_pay[20],f_pay[21]} <= tcnt;
              f_plen <= 6'(LEN_FILL); f_dmac <= F_MAC; f_dip <= F_IP;
              f_send <= 1'b1; seq_f <= seq_f + 16'd1;
              st <= cap_book ? S_BOOK_F : S_IDLE;
            end
          end else if (!p_busy) begin
            hdr(p_pay, T_FILL, seq_p);
            p_pay[4] <= c_oid_rs[31:24]; p_pay[5] <= c_oid_rs[23:16];
            p_pay[6] <= c_oid_rs[15:8];  p_pay[7] <= c_oid_rs[7:0];
            p_pay[8] <= c_fill_px[31:24]; p_pay[9] <= c_fill_px[23:16];
            p_pay[10]<= c_fill_px[15:8];  p_pay[11]<= c_fill_px[7:0];
            p_pay[12]<= c_fill_sz[15:8];  p_pay[13]<= c_fill_sz[7:0];
            {p_pay[14],p_pay[15],p_pay[16],p_pay[17],
             p_pay[18],p_pay[19],p_pay[20],p_pay[21]} <= tcnt;
            p_plen <= 6'(LEN_FILL); p_dmac <= P_MAC; p_dip <= P_IP;
            p_send <= 1'b1; seq_p <= seq_p + 16'd1;
            st <= cap_book ? S_BOOK_F : S_IDLE;
          end
        end

        S_BOOK_F: begin
          if (!f_busy) begin
            hdr(f_pay, T_BOOK, seq_f);
            f_pay[4]  <= bid_px[31:24]; f_pay[5] <= bid_px[23:16];
            f_pay[6]  <= bid_px[15:8];  f_pay[7] <= bid_px[7:0];
            f_pay[8]  <= bid_v ? bid_sz[15:8] : 8'h00;
            f_pay[9]  <= bid_v ? bid_sz[7:0]  : 8'h00;
            f_pay[10] <= ask_px[31:24]; f_pay[11]<= ask_px[23:16];
            f_pay[12] <= ask_px[15:8];  f_pay[13]<= ask_px[7:0];
            f_pay[14] <= ask_v ? ask_sz[15:8] : 8'h00;
            f_pay[15] <= ask_v ? ask_sz[7:0]  : 8'h00;
            {f_pay[16],f_pay[17],f_pay[18],f_pay[19],
             f_pay[20],f_pay[21],f_pay[22],f_pay[23]} <= tcnt;
            f_plen <= 6'(LEN_BOOK); f_dmac <= F_MAC; f_dip <= F_IP;
            f_send <= 1'b1; seq_f <= seq_f + 16'd1;
            st <= S_BOOK_P;
          end
        end

        S_BOOK_P: begin
          if (!p_busy) begin
            hdr(p_pay, T_BOOK, seq_p);
            p_pay[4]  <= bid_px[31:24]; p_pay[5] <= bid_px[23:16];
            p_pay[6]  <= bid_px[15:8];  p_pay[7] <= bid_px[7:0];
            p_pay[8]  <= bid_v ? bid_sz[15:8] : 8'h00;
            p_pay[9]  <= bid_v ? bid_sz[7:0]  : 8'h00;
            p_pay[10] <= ask_px[31:24]; p_pay[11]<= ask_px[23:16];
            p_pay[12] <= ask_px[15:8];  p_pay[13]<= ask_px[7:0];
            p_pay[14] <= ask_v ? ask_sz[15:8] : 8'h00;
            p_pay[15] <= ask_v ? ask_sz[7:0]  : 8'h00;
            {p_pay[16],p_pay[17],p_pay[18],p_pay[19],
             p_pay[20],p_pay[21],p_pay[22],p_pay[23]} <= tcnt;
            p_plen <= 6'(LEN_BOOK); p_dmac <= P_MAC; p_dip <= P_IP;
            p_send <= 1'b1; seq_p <= seq_p + 16'd1;
            st <= S_IDLE;
          end
        end

        S_FAIR_F: begin
          if (!f_busy) begin
            hdr(f_pay, T_FAIR, seq_f);
            f_pay[4] <= 8'd0; f_pay[5] <= {3'd0, fair_i};
            f_pay[6] <= fv[31:24]; f_pay[7] <= fv[23:16];
            f_pay[8] <= fv[15:8];  f_pay[9] <= fv[7:0];
            {f_pay[10],f_pay[11],f_pay[12],f_pay[13],
             f_pay[14],f_pay[15],f_pay[16],f_pay[17]} <= tcnt;
            f_plen <= 6'(LEN_FAIR); f_dmac <= F_MAC; f_dip <= F_IP;
            f_send <= 1'b1; seq_f <= seq_f + 16'd1;
            st <= S_FAIR_P;
          end
        end

        S_FAIR_P: begin
          if (!p_busy) begin
            hdr(p_pay, T_FAIR, seq_p);
            p_pay[4] <= 8'd0; p_pay[5] <= {3'd0, fair_i};
            p_pay[6] <= fv[31:24]; p_pay[7] <= fv[23:16];
            p_pay[8] <= fv[15:8];  p_pay[9] <= fv[7:0];
            {p_pay[10],p_pay[11],p_pay[12],p_pay[13],
             p_pay[14],p_pay[15],p_pay[16],p_pay[17]} <= tcnt;
            p_plen <= 6'(LEN_FAIR); p_dmac <= P_MAC; p_dip <= P_IP;
            p_send <= 1'b1; seq_p <= seq_p + 16'd1;
            want_fair <= 1'b0;
            cap_ack <= 1'b0; cap_fill <= 1'b0; cap_book <= 1'b0;
            cap_snipe <= 1'b0; cap_late <= 1'b0;
            st <= S_IDLE;
          end
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
