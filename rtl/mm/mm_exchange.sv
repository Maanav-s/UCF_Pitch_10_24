`timescale 1ns / 1ps
// Exchange core (docs/mm_protocol.md): two Ethernet ports, the AAPL price
// script, the ETF book, the event log with its UART dump, and the race
// statistics. Everything here runs on clk (50 MHz from the board's
// oscillator); the two PHY clocks only reach the rmii_port instances.
//
// Data path per port: rmii_port -> fix_frame_parse -> event FIFO -> mm_book
// -> fix_frame_gen -> rmii_port(s). The book takes one event at a time and
// the generator writes one frame at a time, one byte per clock, so a frame
// enters a TX FIFO in about 3 us and the FIFO plays it out at wire speed.
// An X (market data) is written into both TX FIFOs in the same clocks.
//
// Script: next_step sends the next AAPL print of mm_fix_pkg::SCRIPT_PRICE;
// play sends the remaining ones GAP_CLKS apart. clear returns to step 0 and
// empties the book, the log and the statistics. The traders are not told, so
// clear them too (the FPGA trader shares BTNU; restart the laptop trader).
//
// Race statistics, per AAPL print: lat_f / lat_l are the clocks from the
// print's first byte entering the TX FIFOs to the acceptance of the first
// frame from port F / port L; f_first says which came first; gap is the
// difference. A receive is stamped when its FCS has been checked, a few
// clocks after its last byte; a transmit when its first byte is written,
// about 40 clocks before it is on the wire (FIFO plus preamble).

module mm_exchange
  import mm_fix_pkg::*;
  import mm_pkg::*;
#(
  parameter int GAP_CLKS   = 50_000_000,  // 1 s between auto-played prints
  parameter int LOG_N      = 1024,
  parameter int CLK_HZ     = 50_000_000,
  parameter int BAUD       = 115200,
  parameter bit TX_NEGEDGE = 1'b0
) (
  input  logic        clk,
  input  logic        rst,

  // Controls (clk, pulses unless noted)
  input  logic        next_step,
  input  logic        play,
  input  logic        clear,
  input  logic        dump_start,
  input  logic [1:0]  label,          // level

  // Port L (laptop), PHY clock domain l_clk
  input  logic        l_clk,
  input  logic        l_crs_dv,
  input  logic [1:0]  l_rxd,
  output logic        l_tx_en,
  output logic [1:0]  l_txd,
  output logic        l_rx_active,    // l_clk
  // Port F (FPGA trader), PHY clock domain f_clk
  input  logic        f_clk,
  input  logic        f_crs_dv,
  input  logic [1:0]  f_rxd,
  output logic        f_tx_en,
  output logic [1:0]  f_txd,
  output logic        f_rx_active,    // f_clk

  // Status (clk)
  output logic        rs_tx,
  output logic        dump_busy,
  output logic        busy,           // a print or an order is being processed
  output logic        script_done,
  output logic        play_active,
  output logic        bid_valid,
  output logic        ask_valid,
  output logic        log_full,
  output logic        rx_bad_seen,
  output logic [31:0] n_steps,
  output logic [31:0] n_fills,
  output logic        race_valid,     // lat_f and lat_l both measured for the last print
  output logic        f_first,        // port F's frame came first
  output logic [31:0] lat_f,          // clocks
  output logic [31:0] lat_l,
  output logic [31:0] gap             // |lat_l - lat_f|
);

  // ---------------------------------------------------------------- ports

  logic        l_rx_valid, l_rx_eof, f_rx_valid, f_rx_eof;
  logic [7:0]  l_rx_data, f_rx_data;
  logic        l_tx_valid, l_tx_ready, f_tx_valid, f_tx_ready;

  logic        g_valid, g_last, g_ready, g_busy;
  logic [7:0]  g_data;
  logic [1:0]  g_port;

  rmii_port #(.TX_NEGEDGE(TX_NEGEDGE)) u_port_l (
    .phy_clk       (l_clk),
    .rmii_crs_dv   (l_crs_dv),
    .rmii_rxd      (l_rxd),
    .rmii_tx_en    (l_tx_en),
    .rmii_txd      (l_txd),
    .phy_rx_active (l_rx_active),
    .phy_tx_active (),
    .clk           (clk),
    .rst           (rst),
    .rx_valid      (l_rx_valid),
    .rx_data       (l_rx_data),
    .rx_eof        (l_rx_eof),
    .tx_valid      (l_tx_valid),
    .tx_data       (g_data),
    .tx_last       (g_last),
    .tx_ready      (l_tx_ready)
  );

  rmii_port #(.TX_NEGEDGE(TX_NEGEDGE)) u_port_f (
    .phy_clk       (f_clk),
    .rmii_crs_dv   (f_crs_dv),
    .rmii_rxd      (f_rxd),
    .rmii_tx_en    (f_tx_en),
    .rmii_txd      (f_txd),
    .phy_rx_active (f_rx_active),
    .phy_tx_active (),
    .clk           (clk),
    .rst           (rst),
    .rx_valid      (f_rx_valid),
    .rx_data       (f_rx_data),
    .rx_eof        (f_rx_eof),
    .tx_valid      (f_tx_valid),
    .tx_data       (g_data),
    .tx_last       (g_last),
    .tx_ready      (f_tx_ready)
  );

  // TX routing: an X goes to both ports in the same clocks.
  wire to_l = (g_port != PORT_F);
  wire to_f = (g_port != PORT_L);

  assign l_tx_valid = g_valid && to_l && (!to_f || f_tx_ready);
  assign f_tx_valid = g_valid && to_f && (!to_l || l_tx_ready);
  assign g_ready    = (!to_l || l_tx_ready) && (!to_f || f_tx_ready);

  // ---------------------------------------------------------------- parsers

  fix_fields_t l_fields, f_fields;
  logic        l_ok, l_bad, f_ok, f_bad;

  fix_frame_parse #(.TRADER_SIDE(1'b0)) u_parse_l (
    .clk          (clk),
    .rst          (rst),
    .in_valid     (l_rx_valid),
    .in_data      (l_rx_data),
    .in_eof       (l_rx_eof),
    .fields       (l_fields),
    .price_bin    (),
    .frame_ok     (l_ok),
    .frame_bad    (l_bad),
    .x_price_done ()
  );

  fix_frame_parse #(.TRADER_SIDE(1'b0)) u_parse_f (
    .clk          (clk),
    .rst          (rst),
    .in_valid     (f_rx_valid),
    .in_data      (f_rx_data),
    .in_eof       (f_rx_eof),
    .fields       (f_fields),
    .price_bin    (),
    .frame_ok     (f_ok),
    .frame_bad    (f_bad),
    .x_price_done ()
  );

  // ---------------------------------------------------------------- event FIFOs

  localparam int EVW = $bits(fix_fields_t);

  // xpm_fifo_sync wants its reset held for a few clocks; clear is a pulse.
  logic [2:0] clr_cnt;
  always_ff @(posedge clk) begin
    if (rst || clear)
      clr_cnt <= 3'd7;
    else if (clr_cnt != 0)
      clr_cnt <= clr_cnt - 3'd1;
  end
  wire fifo_rst = rst || (clr_cnt != 0);

  logic        evf_empty_l, evf_empty_f, evf_take_l, evf_take_f;
  logic        evf_wrb_l, evf_wrb_f, evf_rdb_l, evf_rdb_f, evf_full_l, evf_full_f;
  logic [EVW-1:0] evf_dout_l, evf_dout_f;

  xpm_fifo_sync #(
    .DOUT_RESET_VALUE    ("0"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_MEMORY_TYPE    ("distributed"),
    .FIFO_READ_LATENCY   (0),
    .FIFO_WRITE_DEPTH    (16),
    .FULL_RESET_VALUE    (0),
    .PROG_EMPTY_THRESH   (10),
    .PROG_FULL_THRESH    (10),
    .RD_DATA_COUNT_WIDTH (1),
    .READ_DATA_WIDTH     (EVW),
    .READ_MODE           ("fwft"),
    .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0000"),
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (EVW),
    .WR_DATA_COUNT_WIDTH (1)
  ) u_evf_l (
    .sleep         (1'b0),
    .rst           (fifo_rst),
    .wr_clk        (clk),
    .wr_en         (l_ok && !evf_wrb_l && !evf_full_l),
    .din           (l_fields),
    .full          (evf_full_l),
    .prog_full     (),
    .wr_data_count (),
    .overflow      (),
    .wr_rst_busy   (evf_wrb_l),
    .almost_full   (),
    .wr_ack        (),
    .rd_en         (evf_take_l),
    .dout          (evf_dout_l),
    .empty         (evf_empty_l),
    .prog_empty    (),
    .rd_data_count (),
    .underflow     (),
    .rd_rst_busy   (evf_rdb_l),
    .almost_empty  (),
    .data_valid    (),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       ()
  );

  xpm_fifo_sync #(
    .DOUT_RESET_VALUE    ("0"),
    .ECC_MODE            ("no_ecc"),
    .FIFO_MEMORY_TYPE    ("distributed"),
    .FIFO_READ_LATENCY   (0),
    .FIFO_WRITE_DEPTH    (16),
    .FULL_RESET_VALUE    (0),
    .PROG_EMPTY_THRESH   (10),
    .PROG_FULL_THRESH    (10),
    .RD_DATA_COUNT_WIDTH (1),
    .READ_DATA_WIDTH     (EVW),
    .READ_MODE           ("fwft"),
    .SIM_ASSERT_CHK      (0),
    .USE_ADV_FEATURES    ("0000"),
    .WAKEUP_TIME         (0),
    .WRITE_DATA_WIDTH    (EVW),
    .WR_DATA_COUNT_WIDTH (1)
  ) u_evf_f (
    .sleep         (1'b0),
    .rst           (fifo_rst),
    .wr_clk        (clk),
    .wr_en         (f_ok && !evf_wrb_f && !evf_full_f),
    .din           (f_fields),
    .full          (evf_full_f),
    .prog_full     (),
    .wr_data_count (),
    .overflow      (),
    .wr_rst_busy   (evf_wrb_f),
    .almost_full   (),
    .wr_ack        (),
    .rd_en         (evf_take_f),
    .dout          (evf_dout_f),
    .empty         (evf_empty_f),
    .prog_empty    (),
    .rd_data_count (),
    .underflow     (),
    .rd_rst_busy   (evf_rdb_f),
    .almost_empty  (),
    .data_valid    (),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .sbiterr       (),
    .dbiterr       ()
  );

  // ---------------------------------------------------------------- script

  logic        md_pending, md_ack;
  logic [23:0] md_price;
  logic [$clog2(SCRIPT_N + 1)-1:0] step;
  logic [31:0] gap_cnt;

  wire step_left = (step < SCRIPT_N);
  wire fire      = !md_pending && step_left
                   && (next_step || (play_active && gap_cnt == 0));

  assign script_done = !step_left;

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      md_pending  <= 1'b0;
      md_price    <= '0;
      step        <= '0;
      play_active <= 1'b0;
      gap_cnt     <= '0;
      n_steps     <= '0;
    end else begin
      if (play && step_left) begin
        play_active <= 1'b1;
        gap_cnt     <= '0;
      end
      if (play_active) begin
        if (gap_cnt != 0)
          gap_cnt <= gap_cnt - 32'd1;
        if (!step_left && !md_pending)
          play_active <= 1'b0;
      end
      if (fire) begin
        md_pending <= 1'b1;
        md_price   <= SCRIPT_PRICE[step];
        step       <= step + 1'b1;
        n_steps    <= n_steps + 32'd1;
        gap_cnt    <= 32'(GAP_CLKS);
      end
      if (md_ack)
        md_pending <= 1'b0;
    end
  end

  // ---------------------------------------------------------------- book, generator

  logic        b_tx_start, b_busy, b_fill;
  fix_fields_t b_tx_fields;

  mm_book u_book (
    .clk         (clk),
    .rst         (rst),
    .clear       (clear),
    .md_req      (md_pending),
    .md_price    (md_price),
    .md_ack      (md_ack),
    .ev_valid_f  (!evf_empty_f && !evf_rdb_f),
    .ev_fields_f (evf_dout_f),
    .ev_take_f   (evf_take_f),
    .ev_valid_l  (!evf_empty_l && !evf_rdb_l),
    .ev_fields_l (evf_dout_l),
    .ev_take_l   (evf_take_l),
    .tx_start    (b_tx_start),
    .tx_fields   (b_tx_fields),
    .tx_port     (g_port),
    .tx_busy     (g_busy),
    .busy        (b_busy),
    .bid_valid   (bid_valid),
    .ask_valid   (ask_valid),
    .fill        (b_fill),
    .n_fills     (n_fills),
    .n_orders    (),
    .n_cancels   (),
    .n_rejects   ()
  );

  fix_frame_gen u_gen (
    .clk       (clk),
    .rst       (rst),
    .start     (b_tx_start),
    .f_in      (b_tx_fields),
    .out_valid (g_valid),
    .out_data  (g_data),
    .out_last  (g_last),
    .out_ready (g_ready),
    .busy      (g_busy)
  );

  assign busy = b_busy || md_pending || g_busy;

  // ---------------------------------------------------------------- timestamps, race

  logic [31:0] ts, t_md;
  logic        seen_f, seen_l;

  wire md_sent = b_tx_start && b_tx_fields.mtype == MT_X && b_tx_fields.sym == SYM_AAPL;

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      ts         <= '0;
      t_md       <= '0;
      seen_f     <= 1'b0;
      seen_l     <= 1'b0;
      lat_f      <= '0;
      lat_l      <= '0;
      gap        <= '0;
      f_first    <= 1'b0;
      race_valid <= 1'b0;
    end else begin
      ts <= ts + 32'd1;
      if (md_sent) begin
        t_md       <= ts;
        seen_f     <= 1'b0;
        seen_l     <= 1'b0;
        race_valid <= 1'b0;
      end else begin
        if (f_ok && !seen_f) begin
          seen_f  <= 1'b1;
          lat_f   <= ts - t_md;
          f_first <= !seen_l;
        end
        if (l_ok && !seen_l) begin
          seen_l <= 1'b1;
          lat_l  <= ts - t_md;
          if (!seen_f)
            f_first <= 1'b0;
        end
        if (seen_f && seen_l && !race_valid) begin
          race_valid <= 1'b1;
          gap        <= f_first ? (lat_l - lat_f) : (lat_f - lat_l);
        end
      end
    end
  end

  // ---------------------------------------------------------------- event log

  // Up to three events can happen in one clock (a send and a receive on each
  // port); each source holds its entry until the log has taken it. A source
  // produces at most one event per frame time, so one register each is enough.
  log_entry_t  e_tx, e_l, e_f, e_wr;
  logic        p_tx, p_l, p_f, log_we;

  function automatic log_entry_t rx_entry(input logic [31:0] t, input logic [1:0] port,
                                          input fix_fields_t f);
    log_entry_t e;
    e         = '0;
    e.ts      = t;
    e.dir_tx  = 1'b0;
    e.port    = port;
    e.mtype   = f.mtype;
    e.side    = f.side;
    e.status  = 8'h00;
    e.clordid = f.clordid;
    e.ordid   = (f.mtype == MT_F) ? f.orig : 20'd0;
    e.price   = (f.mtype == MT_F) ? 24'd0 : f.price;  // a cancel has no price
    return e;
  endfunction

  function automatic log_entry_t tx_entry(input logic [31:0] t, input logic [1:0] port,
                                          input fix_fields_t f);
    log_entry_t e;
    e         = '0;
    e.ts      = t;
    e.dir_tx  = 1'b1;
    e.port    = port;
    e.mtype   = f.mtype;
    e.side    = (f.mtype == MT_X) ? f.entry : (f.mtype == MT_ER) ? f.side : 8'h00;
    e.status  = (f.mtype == MT_ER) ? f.exectype : (f.mtype == MT_CR) ? f.reason : 8'h00;
    e.clordid = f.clordid;
    e.ordid   = f.ordid;
    e.price   = f.price;
    return e;
  endfunction

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      p_tx <= 1'b0;
      p_l  <= 1'b0;
      p_f  <= 1'b0;
    end else begin
      if (b_tx_start) begin
        e_tx <= tx_entry(ts, g_port, b_tx_fields);
        p_tx <= 1'b1;
      end else if (p_tx) begin
        p_tx <= 1'b0;
      end
      if (l_ok) begin
        e_l <= rx_entry(ts, PORT_L, l_fields);
        p_l <= 1'b1;
      end else if (p_l && !p_tx) begin
        p_l <= 1'b0;
      end
      if (f_ok) begin
        e_f <= rx_entry(ts, PORT_F, f_fields);
        p_f <= 1'b1;
      end else if (p_f && !p_tx && !p_l) begin
        p_f <= 1'b0;
      end
    end
  end

  always_comb begin
    log_we = p_tx || p_l || p_f;
    e_wr   = p_tx ? e_tx : p_l ? e_l : e_f;
  end

  localparam int LOG_AW = $clog2(LOG_N);

  logic [LOG_AW-1:0] log_addr;
  log_entry_t        log_data;
  logic [31:0]       n_events, n_bad;

  mm_event_log #(.N(LOG_N)) u_log (
    .clk      (clk),
    .rst      (rst),
    .clear    (clear),
    .we       (log_we),
    .entry    (e_wr),
    .rd_addr  (log_addr),
    .rd_data  (log_data),
    .n_events (n_events),
    .full     (log_full)
  );

  always_ff @(posedge clk) begin
    if (rst || clear)
      n_bad <= '0;
    else
      n_bad <= n_bad + 32'(l_bad) + 32'(f_bad);
  end

  assign rx_bad_seen = (n_bad != 0);

  mm_dump #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .N(LOG_N), .TICK_NS(20)) u_dump (
    .clk      (clk),
    .rst      (rst),
    .start    (dump_start),
    .label    (label),
    .rd_addr  (log_addr),
    .rd_data  (log_data),
    .n_events (n_events),
    .n_steps  (n_steps),
    .n_fills  (n_fills),
    .n_bad    (n_bad),
    .tx       (rs_tx),
    .busy     (dump_busy)
  );

endmodule
