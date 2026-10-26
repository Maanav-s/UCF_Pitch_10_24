`timescale 1ns / 1ps
// Order book and matching engine for the ETF (docs/mm_protocol.md, "Exchange
// rules"). The book is two orders: one resting bid and one resting ask. The
// reference is class Exchange in tools/mm_model.py; this module produces the
// same messages in the same order.
//
// Inputs are taken one at a time, when idle:
//   - md_req: send an AAPL print (35=X, 55=AAPL, 269=2, 270=md_price) to
//     both ports. Acknowledged with md_ack when taken.
//   - ev_valid_f / ev_valid_l: a parsed D or F from port F / port L (first
//     word of the port's event FIFO, first-word-fall-through). ev_take_*
//     pops it. Port F and port L alternate priority.
// Each input produces 1 to 3 messages, handed to one fix_frame_gen through
// tx_start / tx_fields / tx_port, one at a time (tx_busy from the generator).
// 34 MsgSeqNum is one counter for all messages; 37 OrderID another, used up
// only by orders that rest or fill.

module mm_book
  import mm_fix_pkg::*;
  import mm_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        clear,         // empty the book, reset counters

  input  logic        md_req,
  input  logic [23:0] md_price,      // BCD cents
  output logic        md_ack,        // pulse: md_req taken

  input  logic        ev_valid_f,
  input  fix_fields_t ev_fields_f,
  output logic        ev_take_f,
  input  logic        ev_valid_l,
  input  fix_fields_t ev_fields_l,
  output logic        ev_take_l,

  output logic        tx_start,
  output fix_fields_t tx_fields,
  output logic [1:0]  tx_port,
  input  logic        tx_busy,

  output logic        busy,
  output logic        bid_valid,
  output logic        ask_valid,
  output logic        fill,          // pulse: a trade happened
  output logic [31:0] n_fills,
  output logic [31:0] n_orders,      // D messages taken
  output logic [31:0] n_cancels,     // F messages taken
  output logic [31:0] n_rejects      // 8 rejected and 9 sent
);

  // ---------------------------------------------------------------- book

  typedef struct packed {
    logic        valid;
    logic        trader;    // 0 = L, 1 = F
    logic [19:0] clordid;
    logic [19:0] ordid;
    logic [23:0] price;     // BCD; packed BCD compares like binary
    logic [19:0] qty;
  } rest_t;

  typedef struct packed {
    logic        valid;
    logic [19:0] clordid;
    logic [19:0] ordid;
  } last_fill_t;

  rest_t      bid, ask;
  last_fill_t lf_l, lf_f;
  logic [19:0] seq, next_ordid;   // BCD counters

  assign bid_valid = bid.valid;
  assign ask_valid = ask.valid;

  // ---------------------------------------------------------------- helpers

  function automatic fix_fields_t mk_er(input logic [19:0] ordid, input logic [19:0] clordid,
                                        input logic [7:0] exectype, input logic [7:0] ordstatus,
                                        input logic [31:0] sym, input logic [7:0] side,
                                        input logic [23:0] price, input logic [19:0] qty);
    fix_fields_t f;
    f = FIX_FIELDS_ZERO;
    f.mtype     = MT_ER;
    f.ordid     = ordid;
    f.clordid   = clordid;
    f.exectype  = exectype;
    f.ordstatus = ordstatus;
    f.sym       = sym;
    f.side      = side;
    f.price     = price;
    f.qty       = qty;
    return f;
  endfunction

  function automatic fix_fields_t mk_x(input logic [31:0] sym, input logic [7:0] entry,
                                       input logic [23:0] price, input logic [19:0] size);
    fix_fields_t f;
    f = FIX_FIELDS_ZERO;
    f.mtype = MT_X;
    f.sym   = sym;
    f.entry = entry;
    f.price = price;
    f.size  = size;
    return f;
  endfunction

  function automatic fix_fields_t mk_cr(input logic [19:0] ordid, input logic [19:0] clordid,
                                        input logic [19:0] orig, input logic [7:0] ordstatus,
                                        input logic [7:0] reason);
    fix_fields_t f;
    f = FIX_FIELDS_ZERO;
    f.mtype     = MT_CR;
    f.ordid     = ordid;
    f.clordid   = clordid;
    f.orig      = orig;
    f.ordstatus = ordstatus;
    f.reason    = reason;
    return f;
  endfunction

  function automatic fix_fields_t with_seq(input fix_fields_t f, input logic [19:0] seq);
    fix_fields_t r;
    r     = f;
    r.seq = seq;
    return r;
  endfunction

  // ---------------------------------------------------------------- decision

  fix_fields_t ev;        // the event being processed
  logic        ev_port;   // 0 = L, 1 = F

  // Outputs of the decision, registered in S_DECIDE.
  fix_fields_t d_msg [3];
  logic [1:0]  d_port [3];
  logic [1:0]  d_n;
  rest_t       d_bid, d_ask;
  last_fill_t  d_lf_l, d_lf_f;
  logic        d_use_ordid, d_fill, d_reject;

  always_comb begin : decide
    rest_t      same, opp;
    last_fill_t lf;
    logic       sym_etf, is_buy, is_sell, side_ok, crosses, better;
    logic [1:0] n;

    sym_etf = (ev.sym == SYM_ETF);
    is_buy  = (ev.side == CH_BUY);
    is_sell = (ev.side == CH_SELL);
    side_ok = is_buy || is_sell;
    same    = is_sell ? ask : bid;
    opp     = is_sell ? bid : ask;
    lf      = ev_port ? lf_f : lf_l;

    for (int i = 0; i < 3; i++) begin
      d_msg[i]  = FIX_FIELDS_ZERO;
      d_port[i] = PORT_L;
    end
    n           = 2'd0;
    d_bid       = bid;
    d_ask       = ask;
    d_lf_l      = lf_l;
    d_lf_f      = lf_f;
    d_use_ordid = 1'b0;
    d_fill      = 1'b0;
    d_reject    = 1'b0;

    if (ev.mtype == MT_F) begin
      if (sym_etf && side_ok && same.valid && same.trader == ev_port
          && same.clordid == ev.orig) begin
        d_msg[0]  = mk_er(same.ordid, ev.orig, CH_CANCELED, CH_CANCELED, SYM_ETF,
                          ev.side, same.price, same.qty);
        d_port[0] = {1'b0, ev_port};
        d_msg[1]  = mk_x(SYM_ETF, is_sell ? CH_OFFER : CH_BID, same.price, 20'd0);
        d_port[1] = PORT_BOTH;
        n         = 2'd2;
        if (is_sell) d_ask.valid = 1'b0;
        else         d_bid.valid = 1'b0;
      end else if (lf.valid && lf.clordid == ev.orig) begin
        d_msg[0]  = mk_cr(lf.ordid, ev.clordid, ev.orig, CH_FILLED, CH_TOOLATE);
        d_port[0] = {1'b0, ev_port};
        n         = 2'd1;
        d_reject  = 1'b1;
      end else begin
        d_msg[0]  = mk_cr(20'd0, ev.clordid, ev.orig, CH_REJECTED, CH_UNKNOWN);
        d_port[0] = {1'b0, ev_port};
        n         = 2'd1;
        d_reject  = 1'b1;
      end
    end else begin
      crosses = opp.valid && (is_sell ? (ev.price <= opp.price) : (ev.price >= opp.price));
      better  = !same.valid || (is_sell ? (ev.price < same.price) : (ev.price > same.price));
      if (!sym_etf || !side_ok || (crosses && opp.trader == ev_port) || (!crosses && !better)) begin
        d_msg[0]  = mk_er(20'd0, ev.clordid, CH_REJECTED, CH_REJECTED, ev.sym, ev.side,
                          ev.price, ev.qty);
        d_port[0] = {1'b0, ev_port};
        n         = 2'd1;
        d_reject  = 1'b1;
      end else if (crosses) begin
        d_msg[0]  = mk_er(next_ordid, ev.clordid, CH_TRADEX, CH_FILLED, SYM_ETF, ev.side,
                          opp.price, ev.qty);
        d_port[0] = {1'b0, ev_port};
        d_msg[1]  = mk_er(opp.ordid, opp.clordid, CH_TRADEX, CH_FILLED, SYM_ETF,
                          is_sell ? CH_BUY : CH_SELL, opp.price, opp.qty);
        d_port[1] = {1'b0, opp.trader};
        d_msg[2]  = mk_x(SYM_ETF, is_sell ? CH_BID : CH_OFFER, opp.price, 20'd0);
        d_port[2] = PORT_BOTH;
        n         = 2'd3;
        if (opp.trader) d_lf_f = '{1'b1, opp.clordid, opp.ordid};
        else            d_lf_l = '{1'b1, opp.clordid, opp.ordid};
        if (ev_port)    d_lf_f = '{1'b1, ev.clordid, next_ordid};
        else            d_lf_l = '{1'b1, ev.clordid, next_ordid};
        d_use_ordid = 1'b1;
        d_fill      = 1'b1;
        if (is_sell) d_bid.valid = 1'b0;
        else         d_ask.valid = 1'b0;
      end else begin
        if (same.valid) begin
          d_msg[n]  = mk_er(same.ordid, same.clordid, CH_CANCELED, CH_CANCELED, SYM_ETF,
                            ev.side, same.price, same.qty);
          d_port[n] = {1'b0, same.trader};
          n         = n + 2'd1;
        end
        d_msg[n]  = mk_er(next_ordid, ev.clordid, CH_NEW, CH_NEW, SYM_ETF, ev.side,
                          ev.price, ev.qty);
        d_port[n] = {1'b0, ev_port};
        n         = n + 2'd1;
        d_msg[n]  = mk_x(SYM_ETF, is_sell ? CH_OFFER : CH_BID, ev.price, ev.qty);
        d_port[n] = PORT_BOTH;
        n         = n + 2'd1;
        if (is_sell) d_ask = '{1'b1, ev_port, ev.clordid, next_ordid, ev.price, ev.qty};
        else         d_bid = '{1'b1, ev_port, ev.clordid, next_ordid, ev.price, ev.qty};
        d_use_ordid = 1'b1;
      end
    end
    d_n = n;
  end

  // ---------------------------------------------------------------- sequencer

  typedef enum logic [2:0] {S_IDLE, S_DECIDE, S_EMIT, S_EMIT_WAIT} state_t;

  (* fsm_encoding = "none" *) state_t state;
  fix_fields_t msg [3];
  logic [1:0]  port [3];
  logic [1:0]  n_msg, i_msg;
  logic        prio_f;   // port F has priority this time

  assign busy = (state != S_IDLE);

  always_ff @(posedge clk) begin
    tx_start  <= 1'b0;
    md_ack    <= 1'b0;
    ev_take_f <= 1'b0;
    ev_take_l <= 1'b0;
    fill      <= 1'b0;
    if (rst || clear) begin
      state      <= S_IDLE;
      bid        <= '0;
      ask        <= '0;
      lf_l       <= '0;
      lf_f       <= '0;
      seq        <= '0;
      next_ordid <= 20'h00001;
      prio_f     <= 1'b1;
      n_fills    <= '0;
      n_orders   <= '0;
      n_cancels  <= '0;
      n_rejects  <= '0;
      ev         <= FIX_FIELDS_ZERO;
      ev_port    <= 1'b0;
      n_msg      <= '0;
      i_msg      <= '0;
      for (int i = 0; i < 3; i++) begin
        msg[i]  <= FIX_FIELDS_ZERO;
        port[i] <= PORT_L;
      end
    end else begin
      case (state)
        S_IDLE: begin
          if (md_req) begin
            md_ack  <= 1'b1;
            msg[0]  <= mk_x(SYM_AAPL, CH_TRADE, md_price, QTY_BCD);
            port[0] <= PORT_BOTH;
            n_msg   <= 2'd1;
            i_msg   <= 2'd0;
            state   <= S_EMIT;
          end else if (ev_valid_f && (prio_f || !ev_valid_l)) begin
            ev_take_f <= 1'b1;
            ev        <= ev_fields_f;
            ev_port   <= 1'b1;
            prio_f    <= 1'b0;
            state     <= S_DECIDE;
          end else if (ev_valid_l) begin
            ev_take_l <= 1'b1;
            ev        <= ev_fields_l;
            ev_port   <= 1'b0;
            prio_f    <= 1'b1;
            state     <= S_DECIDE;
          end
        end

        S_DECIDE: begin
          for (int i = 0; i < 3; i++) begin
            msg[i]  <= d_msg[i];
            port[i] <= d_port[i];
          end
          n_msg <= d_n;
          i_msg <= 2'd0;
          bid   <= d_bid;
          ask   <= d_ask;
          lf_l  <= d_lf_l;
          lf_f  <= d_lf_f;
          if (d_use_ordid)
            next_ordid <= bcd_inc5(next_ordid);
          if (d_fill) begin
            fill    <= 1'b1;
            n_fills <= n_fills + 32'd1;
          end
          if (d_reject)
            n_rejects <= n_rejects + 32'd1;
          if (ev.mtype == MT_F)
            n_cancels <= n_cancels + 32'd1;
          else
            n_orders <= n_orders + 32'd1;
          state <= S_EMIT;
        end

        S_EMIT: begin
          if (!tx_busy) begin
            tx_start  <= 1'b1;
            tx_fields <= with_seq(msg[i_msg], bcd_inc5(seq));
            tx_port   <= port[i_msg];
            seq       <= bcd_inc5(seq);
            state         <= S_EMIT_WAIT;
          end
        end

        // tx_busy is high from the cycle after tx_start.
        S_EMIT_WAIT: begin
          if (!tx_busy) begin
            if (i_msg + 2'd1 == n_msg) begin
              state <= S_IDLE;
            end else begin
              i_msg <= i_msg + 2'd1;
              state <= S_EMIT;
            end
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
