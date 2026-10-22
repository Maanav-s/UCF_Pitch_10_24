`timescale 1ns / 1ps
// Testbench for exchange_core (with latency_timer, rmii_tx and rmii_rx),
// sample_log and exchange_dump, wired as in exchange.sv.
//
// A trader model sits on the other end of the RMII wires: an rmii_rx on the
// exchange's TX pins and an rmii_tx driving the exchange's RX pins. When it
// has received a market-data frame, it waits reply_delay clocks and sends a
// reply chosen by reply_mode.
//
// The testbench measures the latency from the wires itself: from the clock
// edge that drives the exchange's first TX_EN-high dibit to the edge that
// samples the reply's last CRS_DV-high dibit. Every lat_valid from the
// exchange is checked against that.
//
// Tests
//   1. Good reply, 100-clock trader delay: market data is MD_FRAME with FCS
//      4d 73 8b b3, latency matches the wires.
//   2. Same with a 1000-clock delay: latency is exactly 900 ticks more.
//   3. Laptop-style reply (other source MAC, IP ID, flags, TTL, checksums):
//      accepted.
//   4. A junk frame, then the good reply: junk counted in n_other, reply timed.
//   5. Wrong reply (side 54=2): not accepted, the send times out.
//   6. Reply after the timeout: timeout, then counted in n_stale.
//   7. auto_send: 3 sends in a row, each timed; min/max; clear.
//   8. Run of RUN_LEN sends with rising trader delays and one wrong reply:
//      exactly RUN_LEN sends, one log entry each (timeout = 0xFFFFFFFF),
//      run_done. Then the UART dump, decoded from the TX line: header, one
//      line per entry matching the latencies the wires gave, summary line.
//      A send pulse during the dump is ignored (hold).
//   9. Dump with an empty log: header with samples=0, then the summary.
//
// Prints "TB_EXCHANGE PASS" or "TB_EXCHANGE FAIL (<n> errors)" at the end.

module tb_exchange;

  import fix_packets_pkg::*;
  import crc32_pkg::*;

  localparam real CLK_PERIOD   = 20.0;  // 50 MHz REF_CLK
  localparam int  TIMEOUT_CLKS = 5000;
  localparam int  GAP_CLKS     = 100;
  localparam int  RUN_LEN      = 5;
  localparam int  UART_DIV     = 10;  // clocks per bit in the dump

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #(CLK_PERIOD / 2) clk = ~clk;

  // ---------------------------------------------------------------- DUT

  logic send = 1'b0, auto_send = 1'b0, clear = 1'b0, run_start = 1'b0, dump_start = 1'b0;

  wire       ex_tx_en;  // exchange -> trader
  wire [1:0] ex_txd;
  wire       tr_tx_en;  // trader -> exchange
  wire [1:0] tr_txd;

  logic        waiting, lat_valid, last_ok, last_timeout, rx_crs, tx_active;
  logic        timed_out, stats_clear, run_active, run_done, dump_busy;
  logic [31:0] lat_last, lat_min, lat_max;
  logic [31:0] n_replies, n_timeouts, n_other, n_stale;

  exchange_core #(
    .TIMEOUT_CLKS (TIMEOUT_CLKS),
    .GAP_CLKS     (GAP_CLKS),
    .RUN_LEN      (RUN_LEN)
  ) dut (
    .clk          (clk),
    .rst          (rst),
    .send         (send),
    .auto_send    (auto_send),
    .clear        (clear),
    .run_start    (run_start),
    .hold         (dump_busy),
    .rmii_crs_dv  (tr_tx_en),
    .rmii_rxd     (tr_txd),
    .rmii_tx_en   (ex_tx_en),
    .rmii_txd     (ex_txd),
    .waiting      (waiting),
    .lat_valid    (lat_valid),
    .timed_out    (timed_out),
    .stats_clear  (stats_clear),
    .run_active   (run_active),
    .run_done     (run_done),
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

  // ---------------------------------------------------------------- log, dump

  logic [$clog2(RUN_LEN)-1:0] log_addr;
  logic [31:0]                log_data, n_samples;
  logic                       log_full, rs_tx;

  sample_log #(.N(RUN_LEN)) u_log (
    .clk       (clk),
    .rst       (rst),
    .clear     (stats_clear),
    .lat_valid (lat_valid),
    .lat       (lat_last),
    .timed_out (timed_out),
    .rd_addr   (log_addr),
    .rd_data   (log_data),
    .n_samples (n_samples),
    .full      (log_full)
  );

  exchange_dump #(
    .CLK_HZ  (50_000_000),
    .BAUD    (50_000_000 / UART_DIV),
    .N       (RUN_LEN),
    .TICK_NS (20)
  ) u_dump (
    .clk        (clk),
    .rst        (rst),
    .start      (dump_start),
    .label      (2'd2),
    .rd_addr    (log_addr),
    .rd_data    (log_data),
    .n_samples  (n_samples),
    .lat_min    (lat_min),
    .lat_max    (lat_max),
    .n_replies  (n_replies),
    .n_timeouts (n_timeouts),
    .n_other    (n_other),
    .n_stale    (n_stale),
    .tx         (rs_tx),
    .busy       (dump_busy)
  );

  // ---------------------------------------------------------------- trader model

  logic        m_rx_valid, m_rx_eof, m_rx_crs;
  logic [7:0]  m_rx_data;
  logic [10:0] m_rx_offset, m_rx_len;

  rmii_rx m_rx (
    .clk         (clk),
    .rst         (rst),
    .rmii_crs_dv (ex_tx_en),
    .rmii_rxd    (ex_txd),
    .rx_valid    (m_rx_valid),
    .rx_data     (m_rx_data),
    .rx_offset   (m_rx_offset),
    .rx_eof      (m_rx_eof),
    .rx_len      (m_rx_len),
    .rx_crs      (m_rx_crs)
  );

  logic       m_tx_valid = 1'b0;
  logic [7:0] m_tx_data  = '0;
  logic       m_tx_last  = 1'b0;
  logic       m_tx_ready, m_tx_busy, m_tx_underrun;

  rmii_tx m_tx (
    .clk         (clk),
    .rst         (rst),
    .tx_valid    (m_tx_valid),
    .tx_data     (m_tx_data),
    .tx_last     (m_tx_last),
    .tx_ready    (m_tx_ready),
    .tx_busy     (m_tx_busy),
    .tx_underrun (m_tx_underrun),
    .rmii_tx_en  (tr_tx_en),
    .rmii_txd    (tr_txd)
  );

  typedef enum {R_GOOD, R_LAPTOP, R_JUNK_FIRST, R_WRONG} reply_t;

  reply_t reply_mode  = R_GOOD;
  int     reply_delay = 100;  // clocks from the market data's rx_eof

  // Test 8: per-message plan, message k = n_md - plan_base - 1.
  bit     use_plan  = 1'b0;
  int     plan_base = 0;

  localparam int REPLY_NO_FCS = REPLY_FRAME_LEN - 4;
  localparam logic [7:0] MD_FCS [4] = '{8'h4d, 8'h73, 8'h8b, 8'hb3};

  int errors = 0;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      $display("ERROR %0t: %s", $time, msg);
      errors++;
    end
  endtask

  logic [7:0] md_got [2048];
  int         n_md     = 0;
  bit         m_active = 1'b0;  // between a market-data frame and the end of its reply

  always @(posedge clk)
    if (m_rx_valid) md_got[m_rx_offset] = m_rx_data;

  logic [7:0] tr_frame [2048];

  // Stream tr_frame[0 .. n-1] into the model's rmii_tx (as in tb_rmii).
  task automatic tr_send(input int n);
    int i;
    i = 0;
    @(negedge clk);
    m_tx_valid = 1'b1;
    m_tx_data  = tr_frame[0];
    m_tx_last  = (n == 1);
    while (i < n) begin
      if (m_tx_ready) begin
        @(negedge clk);
        i++;
        if (i < n) begin
          m_tx_data = tr_frame[i];
          m_tx_last = (i == n - 1);
        end
      end else begin
        @(negedge clk);
      end
    end
    m_tx_valid = 1'b0;
    m_tx_last  = 1'b0;
  endtask

  task automatic load_reply();
    for (int i = 0; i < REPLY_NO_FCS; i++)
      tr_frame[i] = REPLY_FRAME[i];
  endtask

  initial begin
    forever begin
      @(posedge clk iff m_rx_eof);
      n_md++;
      m_active = 1'b1;

      // The exchange must send exactly the stored frame.
      check(m_rx_len == MD_FRAME_LEN + 4,
            $sformatf("market data rx_len %0d, expected %0d", m_rx_len, MD_FRAME_LEN + 4));
      for (int i = 0; i < MD_FRAME_LEN; i++)
        check(md_got[i] === MD_FRAME[i],
              $sformatf("market data byte %0d = %02h, expected %02h", i, md_got[i], MD_FRAME[i]));
      for (int i = 0; i < 4; i++)
        check(md_got[MD_FRAME_LEN + i] === MD_FCS[i],
              $sformatf("market data FCS byte %0d = %02h, expected %02h",
                        i, md_got[MD_FRAME_LEN + i], MD_FCS[i]));

      if (use_plan) begin
        reply_mode  = (n_md - plan_base - 1 == 2) ? R_WRONG : R_GOOD;
        reply_delay = 100 + 200 * (n_md - plan_base - 1);
      end

      repeat (reply_delay) @(posedge clk);

      case (reply_mode)
        R_GOOD: begin
          load_reply();
          tr_send(REPLY_NO_FCS);
        end
        R_LAPTOP: begin
          load_reply();
          tr_frame[6]  = 8'h02; tr_frame[7]  = 8'haa; tr_frame[8]  = 8'hbb;  // source MAC
          tr_frame[9]  = 8'hcc; tr_frame[10] = 8'hdd; tr_frame[11] = 8'hee;
          tr_frame[18] = 8'h12; tr_frame[19] = 8'h34;                        // IP ID
          tr_frame[20] = 8'h40; tr_frame[21] = 8'h00;                        // DF
          tr_frame[22] = 8'h80;                                              // TTL 128
          tr_frame[24] = 8'hbe; tr_frame[25] = 8'hef;                        // IP checksum
          tr_frame[40] = 8'h00; tr_frame[41] = 8'h00;                        // UDP checksum
          tr_send(REPLY_NO_FCS);
        end
        R_JUNK_FIRST: begin
          // ARP-like broadcast, padded to 60 bytes by rmii_tx.
          for (int i = 0; i < 6; i++) tr_frame[i] = 8'hff;
          for (int i = 6; i < 12; i++) tr_frame[i] = REPLY_FRAME[i];
          tr_frame[12] = 8'h08;
          tr_frame[13] = 8'h06;
          tr_send(14);
          @(negedge clk iff !m_tx_busy);
          load_reply();
          tr_send(REPLY_NO_FCS);
        end
        R_WRONG: begin
          load_reply();
          check(tr_frame[92] == "1", "REPLY_FRAME[92] is not the side byte");
          tr_frame[92] = "2";  // 54=2: sell
          tr_send(REPLY_NO_FCS);
        end
      endcase
      m_active = 1'b0;
    end
  end

  // ---------------------------------------------------------------- wire timing

  // t_a: edge that drives the exchange's first TX_EN-high dibit.
  // t_e: edge that samples the trader's last TX_EN-high dibit.
  // Signals are read at the rising edge before the edge updates them.
  int cyc = 0;
  int t_a = 0, t_e = 0;
  bit ex_prev = 1'b0;

  always @(posedge clk) begin
    cyc++;
    if (ex_tx_en && !ex_prev) t_a = cyc - 1;
    ex_prev = ex_tx_en;
    if (tr_tx_en) t_e = cyc;
  end

  int n_lat = 0;
  logic [31:0] outcome_q [$];  // every lat_valid / timed_out, as sample_log stores it

  always @(posedge clk) begin
    if (stats_clear)
      outcome_q.delete();
    if (timed_out)
      outcome_q.push_back(32'hFFFF_FFFF);
    if (lat_valid) begin
      outcome_q.push_back(lat_last);
      n_lat++;
      $display("  latency %0d ticks (%0.2f us)", lat_last, lat_last * CLK_PERIOD / 1000.0);
      check(lat_last == t_e - t_a,
            $sformatf("latency %0d ticks, wires say %0d", lat_last, t_e - t_a));
    end
  end

  // ---------------------------------------------------------------- UART decoder

  string uart_line = "";
  string uart_lines [$];

  initial begin
    logic [7:0] ch;
    forever begin
      @(negedge rs_tx);
      repeat (UART_DIV / 2) @(posedge clk);
      check(rs_tx === 1'b0, "UART start bit not low at mid-bit");
      for (int b = 0; b < 8; b++) begin
        repeat (UART_DIV) @(posedge clk);
        ch[b] = rs_tx;
      end
      repeat (UART_DIV) @(posedge clk);
      check(rs_tx === 1'b1, "UART stop bit not high");
      if (ch == 8'h0A) begin
        uart_lines.push_back(uart_line);
        uart_line = "";
      end else begin
        uart_line = $sformatf("%s%c", uart_line, ch);
      end
    end
  end

  // Pulse dump_start and wait until the dump has been sent and decoded.
  task automatic do_dump();
    uart_lines.delete();
    @(negedge clk);
    dump_start = 1'b1;
    @(negedge clk);
    dump_start = 1'b0;
    @(posedge clk iff !dump_busy);
    repeat (2 * UART_DIV) @(posedge clk);
  endtask

  task automatic check_line(input int i, input string exp);
    if (i >= uart_lines.size())
      check(1'b0, $sformatf("dump line %0d missing, expected '%s'", i, exp));
    else
      check(uart_lines[i] == exp,
            $sformatf("dump line %0d '%s', expected '%s'", i, uart_lines[i], exp));
  endtask

  function automatic string summary();
    return $sformatf("# min=%0d,max=%0d,replies=%0d,timeouts=%0d,other=%0d,stale=%0d",
                     lat_min, lat_max, n_replies, n_timeouts, n_other, n_stale);
  endfunction

  // ---------------------------------------------------------------- tests

  // Pulse send and wait for the reply or the timeout, then until the trader
  // model has finished sending.
  task automatic do_send();
    int r0, to0;
    r0  = n_replies;
    to0 = n_timeouts;
    @(negedge clk);
    send = 1'b1;
    @(negedge clk);
    send = 1'b0;
    for (int c = 0; c < TIMEOUT_CLKS + 2000 && n_replies == r0 && n_timeouts == to0; c++)
      @(posedge clk);
    check(n_replies != r0 || n_timeouts != to0, "neither a reply nor a timeout");
    @(posedge clk iff !m_active);
    repeat (GAP_CLKS + 10) @(posedge clk);
  endtask

  int lat1, n0;

  initial begin
    repeat (5) @(posedge clk);
    rst = 1'b0;
    repeat (5) @(posedge clk);

    $display("Test 1: good reply, trader delay 100 clocks");
    reply_mode  = R_GOOD;
    reply_delay = 100;
    do_send();
    check(n_md == 1, $sformatf("trader got %0d market-data frames, expected 1", n_md));
    check(n_replies == 1 && n_timeouts == 0 && n_other == 0,
          $sformatf("replies %0d, timeouts %0d, other %0d", n_replies, n_timeouts, n_other));
    check(last_ok && !last_timeout, "last_ok/last_timeout wrong");
    lat1 = lat_last;

    $display("Test 2: good reply, trader delay 1000 clocks");
    reply_delay = 1000;
    do_send();
    check(n_replies == 2, $sformatf("replies %0d, expected 2", n_replies));
    check(lat_last == lat1 + 900,
          $sformatf("latency %0d, expected %0d (test 1 + 900)", lat_last, lat1 + 900));

    $display("Test 3: laptop-style reply");
    reply_mode  = R_LAPTOP;
    reply_delay = 100;
    do_send();
    check(n_replies == 3 && n_other == 0,
          $sformatf("replies %0d, other %0d; expected 3, 0", n_replies, n_other));
    check(lat_last == lat1, $sformatf("latency %0d, expected %0d", lat_last, lat1));

    $display("Test 4: junk frame, then the reply");
    reply_mode = R_JUNK_FIRST;
    do_send();
    check(n_replies == 4 && n_other == 1,
          $sformatf("replies %0d, other %0d; expected 4, 1", n_replies, n_other));

    $display("Test 5: wrong reply (sell)");
    reply_mode = R_WRONG;
    do_send();
    check(n_replies == 4 && n_timeouts == 1 && n_other == 2,
          $sformatf("replies %0d, timeouts %0d, other %0d; expected 4, 1, 2",
                    n_replies, n_timeouts, n_other));
    check(last_timeout && !last_ok, "last_timeout/last_ok wrong");

    $display("Test 6: reply after the timeout");
    reply_mode  = R_GOOD;
    reply_delay = TIMEOUT_CLKS + 200;
    do_send();
    check(n_replies == 4 && n_timeouts == 2 && n_stale == 1,
          $sformatf("replies %0d, timeouts %0d, stale %0d; expected 4, 2, 1",
                    n_replies, n_timeouts, n_stale));

    $display("Test 7: auto_send, min/max, clear");
    @(negedge clk);
    clear = 1'b1;
    @(negedge clk);
    clear = 1'b0;
    check(n_replies == 0 && n_timeouts == 0 && n_other == 0 && n_stale == 0
          && lat_min == '1 && lat_max == 0, "clear did not reset the statistics");
    reply_delay = 100;
    n0 = n_lat;
    auto_send = 1'b1;
    for (int c = 0; c < 20000 && n_replies < 3; c++) @(posedge clk);
    auto_send = 1'b0;
    @(posedge clk iff !waiting && !m_active);
    repeat (GAP_CLKS + 10) @(posedge clk);
    check(n_replies >= 3, $sformatf("auto_send: %0d replies, expected at least 3", n_replies));
    check(n_lat - n0 == n_replies, "lat_valid count differs from n_replies");
    check(lat_min == lat1 && lat_max == lat1,
          $sformatf("min %0d, max %0d, expected %0d", lat_min, lat_max, lat1));

    $display("Test 8: run of %0d, then the UART dump", RUN_LEN);
    use_plan  = 1'b1;
    plan_base = n_md;
    @(negedge clk);
    run_start = 1'b1;
    @(negedge clk);
    run_start = 1'b0;
    @(posedge clk iff run_active);
    @(posedge clk iff !run_active);
    @(posedge clk iff !m_active);
    repeat (GAP_CLKS + 10) @(posedge clk);
    use_plan    = 1'b0;
    reply_mode  = R_GOOD;
    reply_delay = 100;
    check(run_done, "run_done not set after the run");
    check(n_md - plan_base == RUN_LEN,
          $sformatf("run sent %0d market-data frames, expected %0d", n_md - plan_base, RUN_LEN));
    check(n_samples == RUN_LEN && log_full,
          $sformatf("sample log has %0d entries, expected %0d", n_samples, RUN_LEN));
    check(outcome_q.size() == RUN_LEN,
          $sformatf("%0d outcomes since the run start, expected %0d", outcome_q.size(), RUN_LEN));
    check(n_replies == RUN_LEN - 1 && n_timeouts == 1 && n_other == 1,
          $sformatf("replies %0d, timeouts %0d, other %0d; expected %0d, 1, 1",
                    n_replies, n_timeouts, n_other, RUN_LEN - 1));
    if (outcome_q.size() == RUN_LEN) begin
      check(outcome_q[2] == 32'hFFFF_FFFF, "entry 2 is not a timeout");
      check(outcome_q[1] == outcome_q[0] + 200 && outcome_q[3] == outcome_q[0] + 600,
            "run latencies do not follow the 200-clock delay steps");
    end

    n0 = n_md;
    fork
      do_dump();
      begin
        // BTNC during the dump: must be ignored.
        repeat (50) @(posedge clk);
        @(negedge clk);
        send = 1'b1;
        @(negedge clk);
        send = 1'b0;
      end
    join
    check(n_md == n0, "a send pulse during the dump sent market data");
    check(uart_lines.size() == RUN_LEN + 2,
          $sformatf("dump has %0d lines, expected %0d", uart_lines.size(), RUN_LEN + 2));
    check_line(0, $sformatf("# run label=C tick_ns=20 samples=%0d", RUN_LEN));
    for (int i = 0; i < RUN_LEN && i < outcome_q.size(); i++)
      check_line(1 + i, $sformatf("%0d,%0d", i, outcome_q[i]));
    check_line(RUN_LEN + 1, summary());
    for (int i = 0; i < uart_lines.size(); i++)
      $display("  dump: %s", uart_lines[i]);

    $display("Test 9: dump with an empty log");
    @(negedge clk);
    clear = 1'b1;
    @(negedge clk);
    clear = 1'b0;
    check(n_samples == 0 && !run_done, "clear did not empty the log / reset run_done");
    do_dump();
    check(uart_lines.size() == 2,
          $sformatf("empty dump has %0d lines, expected 2", uart_lines.size()));
    check_line(0, "# run label=C tick_ns=20 samples=0");
    check_line(1, summary());

    if (errors == 0)
      $display("TB_EXCHANGE PASS");
    else
      $display("TB_EXCHANGE FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #5ms;
    $display("TB_EXCHANGE FAIL (timeout)");
    $finish;
  end

endmodule
