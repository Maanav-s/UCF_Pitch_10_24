`timescale 1ns / 1ps
// Testbench for exchange_core (with latency_timer, rmii_tx and rmii_rx).
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
//
// Prints "TB_EXCHANGE PASS" or "TB_EXCHANGE FAIL (<n> errors)" at the end.

module tb_exchange;

  import fix_packets_pkg::*;
  import crc32_pkg::*;

  localparam real CLK_PERIOD   = 20.0;  // 50 MHz REF_CLK
  localparam int  TIMEOUT_CLKS = 5000;
  localparam int  GAP_CLKS     = 100;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #(CLK_PERIOD / 2) clk = ~clk;

  // ---------------------------------------------------------------- DUT

  logic send = 1'b0, auto_send = 1'b0, clear = 1'b0;

  wire       ex_tx_en;  // exchange -> trader
  wire [1:0] ex_txd;
  wire       tr_tx_en;  // trader -> exchange
  wire [1:0] tr_txd;

  logic        waiting, lat_valid, last_ok, last_timeout, rx_crs, tx_active;
  logic [31:0] lat_last, lat_min, lat_max;
  logic [31:0] n_replies, n_timeouts, n_other, n_stale;

  exchange_core #(
    .TIMEOUT_CLKS (TIMEOUT_CLKS),
    .GAP_CLKS     (GAP_CLKS)
  ) dut (
    .clk          (clk),
    .rst          (rst),
    .send         (send),
    .auto_send    (auto_send),
    .clear        (clear),
    .rmii_crs_dv  (tr_tx_en),
    .rmii_rxd     (tr_txd),
    .rmii_tx_en   (ex_tx_en),
    .rmii_txd     (ex_txd),
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

  always @(posedge clk) begin
    if (lat_valid) begin
      n_lat++;
      $display("  latency %0d ticks (%0.2f us)", lat_last, lat_last * CLK_PERIOD / 1000.0);
      check(lat_last == t_e - t_a,
            $sformatf("latency %0d ticks, wires say %0d", lat_last, t_e - t_a));
    end
  end

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

    if (errors == 0)
      $display("TB_EXCHANGE PASS");
    else
      $display("TB_EXCHANGE FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #2ms;
    $display("TB_EXCHANGE FAIL (timeout)");
    $finish;
  end

endmodule
