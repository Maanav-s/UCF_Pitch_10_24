`timescale 1ns / 1ps
// FPGA market-making trader (docs/mm_protocol.md, "Strategy"). The
// reference is class MarketMaker in tools/mm_model.py; this module sends the
// same messages in the same order. All logic on clk, the LAN8720's 50 MHz
// REF_CLK, so 1 clock = 20 ns. No FIFOs: frames are parsed as they arrive.
//
// Receive (fix_frame_parse, TRADER_SIDE):
//   X, 55=ETF, 269=0/1   at frame end: the book's bid / ask, gone if size 0
//   X, 55=AAPL, 269=2    the decision below, before the frame has ended
//   8                    at frame end, for an own ClOrdID on that side:
//                        150=0 keeps the order, anything else drops it
//   9, other frames      counted, ignored
//
// Decision timing, counted in clocks from the cycle in which rmii_rx's
// rx_valid strobes the last price digit (frame offset 96):
//   +1  x_price_done; price_bin is valid
//   +2  n3   = 3 * price
//   +3  prod = n3 * DIV10_M
//   +4  fair = prod >> DIV10_S + FAIR_OFF_CENTS
//   +5  the actions are chosen and latched (end of the decide cycle)
//   +6  start reaches fix_frame_gen
//   +7  the first byte is offered to rmii_tx
//   +8  TX_EN is high
// So the decision is registered 5 clocks after the strobe and TX_EN rises
// 8 clocks after it (tb_mm_trader checks the 8).
//
// Actions, in order, one frame each (fix_frame_gen -> rmii_tx):
//   1. pickoff: buy at the resting ask if ask < fair and the ask is not our
//      own order; else sell to the resting bid if bid > fair and not ours
//   2. cancel our own bid, then our own ask, if any (decided before the
//      pickoff order, which takes over that side's own-order slot)
//   3. if quoting: bid at fair - half_spread, ask at fair + half_spread
//      (no bid when fair <= half_spread). The two prices go through
//      bin2bcd (24 clocks) in parallel with actions 1 and 2.
// half_spread_dollars and quoting are sampled at DECIDE.
//
// REQUOTE_DELAY_CLKS holds actions 2 and 3 back that many clocks after the
// pickoff, so the old quotes stay stale long enough for a slow trader to
// pick them off. 0 (the default, and what tb_mm_trader checks) adds no
// clocks at all.

module mm_trader
  import mm_fix_pkg::*;
  import mm_pkg::*;
#(
  parameter bit TX_NEGEDGE         = 1'b0,
  parameter int REQUOTE_DELAY_CLKS = 0
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        clear,               // pulse: forget orders, book, counters

  input  logic [3:0]  half_spread_dollars, // 0 counts as 1
  input  logic        quoting,

  input  logic        rmii_crs_dv,
  input  logic [1:0]  rmii_rxd,
  output logic        rmii_tx_en,
  output logic [1:0]  rmii_txd,

  output logic        buy,        // pulse: pickoff buy sent
  output logic        sell,       // pulse: pickoff sell sent
  output logic        quote_sent, // pulse: a quote (D) sent
  output logic [31:0] n_md,       // AAPL prints seen
  output logic [31:0] n_buys,
  output logic [31:0] n_sells,
  output logic [31:0] n_fills,    // own orders filled
  output logic [31:0] n_ignored,  // frames that are not one of ours
  output logic        rx_crs,
  output logic        tx_active
);

  // ---------------------------------------------------------------- RMII, parser

  logic        rx_valid, rx_eof;
  logic [7:0]  rx_data;

  rmii_rx u_rx (
    .clk         (clk),
    .rst         (rst),
    .rmii_crs_dv (rmii_crs_dv),
    .rmii_rxd    (rmii_rxd),
    .rx_valid    (rx_valid),
    .rx_data     (rx_data),
    .rx_offset   (),
    .rx_eof      (rx_eof),
    .rx_len      (),
    .rx_crs      (rx_crs)
  );

  fix_fields_t fields;
  logic [19:0] price_bin;
  logic        frame_ok, frame_bad, x_price_done;

  fix_frame_parse #(.TRADER_SIDE(1'b1)) u_parse (
    .clk          (clk),
    .rst          (rst),
    .in_valid     (rx_valid),
    .in_data      (rx_data),
    .in_eof       (rx_eof),
    .fields       (fields),
    .price_bin    (price_bin),
    .frame_ok     (frame_ok),
    .frame_bad    (frame_bad),
    .x_price_done (x_price_done)
  );

  // ---------------------------------------------------------------- generator, TX

  logic        g_start, g_valid, g_last, g_ready, g_busy, tx_busy;
  logic [7:0]  g_data;
  fix_fields_t g_fields;

  fix_frame_gen u_gen (
    .clk       (clk),
    .rst       (rst),
    .start     (g_start),
    .f_in      (g_fields),
    .out_valid (g_valid),
    .out_data  (g_data),
    .out_last  (g_last),
    .out_ready (g_ready),
    .busy      (g_busy)
  );

  rmii_tx #(.TX_NEGEDGE(TX_NEGEDGE)) u_tx (
    .clk         (clk),
    .rst         (rst),
    .tx_valid    (g_valid),
    .tx_data     (g_data),
    .tx_last     (g_last),
    .tx_ready    (g_ready),
    .tx_busy     (tx_busy),
    .tx_underrun (),
    .rmii_tx_en  (rmii_tx_en),
    .rmii_txd    (rmii_txd)
  );

  assign tx_active = tx_busy;

  // ---------------------------------------------------------------- state

  typedef struct packed {
    logic        valid;
    logic [23:0] price;      // BCD
    logic [19:0] price_bin;  // cents
  } level_t;

  typedef struct packed {
    logic        valid;
    logic [19:0] clordid;
    logic [23:0] price;      // BCD
  } own_t;

  level_t book_bid, book_ask;
  own_t   own_bid, own_ask;
  logic [19:0] seq, next_clordid;   // BCD

  // ---------------------------------------------------------------- fair value pipeline

  logic        s1_v, s2_v, s3_v;
  logic        s1_aapl, s2_aapl, s3_aapl;
  logic [21:0] n3;
  logic [41:0] prod;
  logic [23:0] fair;

  always_ff @(posedge clk) begin
    s1_v    <= x_price_done;
    s1_aapl <= (fields.sym == SYM_AAPL) && (fields.entry == CH_TRADE);
    n3      <= 22'(price_bin) * 22'd3;
    s2_v    <= s1_v;
    s2_aapl <= s1_aapl;
    prod    <= n3 * DIV10_M[19:0];
    s3_v    <= s2_v;
    s3_aapl <= s2_aapl;
    if (s2_v)
      fair <= 24'(prod >> DIV10_S) + 24'(FAIR_OFF_CENTS);
  end

  wire decide = s3_v && s3_aapl;

  // ---------------------------------------------------------------- actions

  function automatic logic [11:0] hs_cents_of(input logic [3:0] dollars);
    return 12'((dollars == 4'd0) ? 4'd1 : dollars) * 12'd100;
  endfunction


  typedef enum logic [2:0] {A_IDLE, A_PICK, A_CXL_BID, A_CXL_ASK, A_QBID, A_QASK, A_WAIT,
                            A_DELAY} act_t;

  // Where the burst goes after the pickoff: straight to the cancels, or
  // through A_DELAY when a requote delay is set.
  localparam act_t A_AFTER_PICK = (REQUOTE_DELAY_CLKS == 0) ? A_CXL_BID : A_DELAY;

  (* fsm_encoding = "none" *) act_t act, act_next;
  logic [31:0] delay_cnt;
  logic        pick, pick_sell, cxl_bid, cxl_ask, q_bid, q_ask;
  logic [23:0] pick_price;
  logic [19:0] cxl_bid_id, cxl_ask_id;
  logic [11:0] hs_cents;

  // Quote prices through bin2bcd.
  logic        bcd_start, bcd_bid_busy, bcd_ask_busy, bcd_pending;
  logic [23:0] bid_bcd, ask_bcd;
  wire  [23:0] bid_bin = fair - 24'(hs_cents);
  wire  [23:0] ask_bin = fair + 24'(hs_cents);

  bin2bcd #(.W(24), .D(6)) u_bcd_bid (
    .clk   (clk),
    .rst   (rst),
    .start (bcd_start),
    .bin   (bid_bin),
    .bcd   (bid_bcd),
    .busy  (bcd_bid_busy),
    .done  ()
  );

  bin2bcd #(.W(24), .D(6)) u_bcd_ask (
    .clk   (clk),
    .rst   (rst),
    .start (bcd_start),
    .bin   (ask_bin),
    .bcd   (ask_bcd),
    .busy  (bcd_ask_busy),
    .done  ()
  );

  wire bcd_ready = !bcd_pending || (!bcd_bid_busy && !bcd_ask_busy && !bcd_start);

  function automatic fix_fields_t mk_order(input logic [19:0] seq_, input logic [19:0] clordid,
                                           input logic [7:0] side, input logic [23:0] price);
    fix_fields_t f;
    f = FIX_FIELDS_ZERO;
    f.mtype   = MT_D;
    f.seq     = seq_;
    f.clordid = clordid;
    f.sym     = SYM_ETF;
    f.side    = side;
    f.qty     = QTY_BCD;
    f.price   = price;
    return f;
  endfunction

  function automatic fix_fields_t mk_cancel(input logic [19:0] seq_, input logic [19:0] clordid,
                                            input logic [19:0] orig, input logic [7:0] side);
    fix_fields_t f;
    f = FIX_FIELDS_ZERO;
    f.mtype   = MT_F;
    f.seq     = seq_;
    f.clordid = clordid;
    f.orig    = orig;
    f.sym     = SYM_ETF;
    f.side    = side;
    return f;
  endfunction

  wire can_start = !g_busy && !g_start;
  wire [19:0] seq_n = bcd_inc5(seq);

  wire ask_below = book_ask.valid && (book_ask.price_bin < fair[19:0])
                   && !(own_ask.valid && own_ask.price == book_ask.price);
  wire bid_above = book_bid.valid && (book_bid.price_bin > fair[19:0])
                   && !(own_bid.valid && own_bid.price == book_bid.price);

  always_ff @(posedge clk) begin
    g_start    <= 1'b0;
    bcd_start  <= 1'b0;
    buy        <= 1'b0;
    sell       <= 1'b0;
    quote_sent <= 1'b0;
    if (rst || clear) begin
      act          <= A_IDLE;
      act_next     <= A_IDLE;
      delay_cnt    <= '0;
      book_bid     <= '0;
      book_ask     <= '0;
      own_bid      <= '0;
      own_ask      <= '0;
      seq          <= '0;
      next_clordid <= 20'h00001;
      n_md         <= '0;
      n_buys       <= '0;
      n_sells      <= '0;
      n_fills      <= '0;
      n_ignored    <= '0;
      pick         <= 1'b0;
      pick_sell    <= 1'b0;
      cxl_bid      <= 1'b0;
      cxl_ask      <= 1'b0;
      q_bid        <= 1'b0;
      q_ask        <= 1'b0;
      pick_price   <= '0;
      cxl_bid_id   <= '0;
      cxl_ask_id   <= '0;
      hs_cents     <= 12'd100;
      bcd_pending  <= 1'b0;
      g_fields     <= FIX_FIELDS_ZERO;
    end else begin
      // ---- frame end: book, own orders, counters
      if (frame_bad)
        n_ignored <= n_ignored + 32'd1;
      if (frame_ok) begin
        case (fields.mtype)
          MT_X: begin
            if (fields.sym == SYM_ETF) begin
              if (fields.entry == CH_BID)
                book_bid <= '{(fields.size != 20'd0), fields.price, price_bin};
              else if (fields.entry == CH_OFFER)
                book_ask <= '{(fields.size != 20'd0), fields.price, price_bin};
            end else if (fields.sym == SYM_AAPL && fields.entry == CH_TRADE) begin
              n_md <= n_md + 32'd1;
            end
          end
          MT_ER: begin
            // Every report is for one of our orders. A fill is counted even
            // when the order is no longer the tracked one on its side (a
            // pickoff order's slot is taken over by the requote that
            // follows it, before its fill report arrives).
            if (fields.exectype == CH_TRADEX)
              n_fills <= n_fills + 32'd1;
            if (fields.side == CH_BUY && own_bid.valid && own_bid.clordid == fields.clordid
                && fields.exectype != CH_NEW)
              own_bid.valid <= 1'b0;
            if (fields.side == CH_SELL && own_ask.valid && own_ask.clordid == fields.clordid
                && fields.exectype != CH_NEW)
              own_ask.valid <= 1'b0;
          end
          default: ;
        endcase
      end

      // ---- decision: latch the actions (a decision during a burst restarts it)
      if (decide) begin
        hs_cents    <= hs_cents_of(half_spread_dollars);
        pick        <= ask_below || bid_above;
        pick_sell   <= !ask_below && bid_above;
        pick_price  <= ask_below ? book_ask.price : book_bid.price;
        cxl_bid     <= own_bid.valid;
        cxl_bid_id  <= own_bid.clordid;
        cxl_ask     <= own_ask.valid;
        cxl_ask_id  <= own_ask.clordid;
        q_bid       <= quoting && (fair > 24'(hs_cents_of(half_spread_dollars)));
        q_ask       <= quoting;
        bcd_start   <= 1'b1;
        bcd_pending <= 1'b1;
        delay_cnt   <= 32'(REQUOTE_DELAY_CLKS);
        act         <= A_PICK;
      end else begin
        case (act)
          A_IDLE: ;

          A_PICK: begin
            if (!pick) begin
              act <= A_AFTER_PICK;
            end else if (can_start) begin
              g_start  <= 1'b1;
              g_fields <= mk_order(seq_n, next_clordid, pick_sell ? CH_SELL : CH_BUY, pick_price);
              if (pick_sell) begin
                own_ask <= '{1'b1, next_clordid, pick_price};
                sell    <= 1'b1;
                n_sells <= n_sells + 32'd1;
              end else begin
                own_bid <= '{1'b1, next_clordid, pick_price};
                buy     <= 1'b1;
                n_buys  <= n_buys + 32'd1;
              end
              seq          <= seq_n;
              next_clordid <= bcd_inc5(next_clordid);
              act_next     <= A_AFTER_PICK;
              act          <= A_WAIT;
            end
          end

          A_DELAY:
            if (delay_cnt == 0)
              act <= A_CXL_BID;
            else
              delay_cnt <= delay_cnt - 32'd1;

          A_CXL_BID: begin
            if (!cxl_bid) begin
              act <= A_CXL_ASK;
            end else if (can_start) begin
              g_start  <= 1'b1;
              g_fields <= mk_cancel(seq_n, next_clordid, cxl_bid_id, CH_BUY);
              if (own_bid.valid && own_bid.clordid == cxl_bid_id)
                own_bid.valid <= 1'b0;
              seq          <= seq_n;
              next_clordid <= bcd_inc5(next_clordid);
              act_next     <= A_CXL_ASK;
              act          <= A_WAIT;
            end
          end

          A_CXL_ASK: begin
            if (!cxl_ask) begin
              act <= A_QBID;
            end else if (can_start) begin
              g_start  <= 1'b1;
              g_fields <= mk_cancel(seq_n, next_clordid, cxl_ask_id, CH_SELL);
              if (own_ask.valid && own_ask.clordid == cxl_ask_id)
                own_ask.valid <= 1'b0;
              seq          <= seq_n;
              next_clordid <= bcd_inc5(next_clordid);
              act_next     <= A_QBID;
              act          <= A_WAIT;
            end
          end

          A_QBID: begin
            if (!q_bid) begin
              act <= A_QASK;
            end else if (can_start && bcd_ready) begin
              g_start      <= 1'b1;
              g_fields     <= mk_order(seq_n, next_clordid, CH_BUY, bid_bcd);
              own_bid      <= '{1'b1, next_clordid, bid_bcd};
              quote_sent   <= 1'b1;
              seq          <= seq_n;
              next_clordid <= bcd_inc5(next_clordid);
              act_next     <= A_QASK;
              act          <= A_WAIT;
            end
          end

          A_QASK: begin
            if (!q_ask) begin
              act         <= A_IDLE;
              bcd_pending <= 1'b0;
            end else if (can_start && bcd_ready) begin
              g_start      <= 1'b1;
              g_fields     <= mk_order(seq_n, next_clordid, CH_SELL, ask_bcd);
              own_ask      <= '{1'b1, next_clordid, ask_bcd};
              quote_sent   <= 1'b1;
              seq          <= seq_n;
              next_clordid <= bcd_inc5(next_clordid);
              act_next     <= A_IDLE;
              act          <= A_WAIT;
              bcd_pending  <= 1'b0;
            end
          end

          // g_busy is high from the cycle after g_start.
          A_WAIT:
            if (!g_busy && !g_start)
              act <= act_next;

          default: act <= A_IDLE;
        endcase
      end
    end
  end

endmodule
