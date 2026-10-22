`timescale 1ns / 1ps
// Testbench for trader_core (with rmii_rx and rmii_tx).
//
// Two traders get the same RMII stimulus from a generator (an rmii_tx):
// dut0 with SPECULATIVE_TX = 0 and dut1 with SPECULATIVE_TX = 1. A monitor
// (an rmii_rx) on each trader's TX pins records what it sends.
//
// Expected replies are built here from REPLY_FRAME, independently of the
// trader's incremental method: patched seq and price, FIX CheckSum summed
// over the payload, UDP checksum summed over the pseudo-header and datagram
// (0 for dut1), FCS from crc32_byte. Every reply is compared byte for byte,
// FCS included.
//
// Timing checks, on every frame:
//   - the decision is registered 1 clock after rx_valid for byte 96;
//   - TX_EN rises 2 clocks after rx_valid for byte 96 (dut0) or byte 0 (dut1).
//
// Tests
//   1. Stored market data (AAPL ask $100.00), limit $100.00: dut0 sends
//      exactly REPLY_FRAME; dut1 the same with UDP checksum 0.
//   2. Limit $99.99: no trade. dut0 sends nothing, dut1 cuts its reply off
//      (wrong FCS).
//   3. Ticker MSFT selected: no trade.
//   4. seq 00042, price $75.25, limit $75.25 (price == limit): buy, with
//      the seq and price copied and both checksums recomputed.
//   5. Same, limit $75.24: no trade.
//   6. Bid (269=0): no trade.
//   7. Other frames: ARP broadcast, a non-digit in the price, a frame cut
//      short before the price, another destination port. Ignored. dut1
//      cuts off the reply it started, except for the broadcast, whose first
//      byte already fails.
//   8. Switches changed in the middle of a frame: the frame uses the old
//      settings.
//   9. Seq 65535, price $0001.00, TSLA, 3 frames in a row, 500 clocks apart:
//      three replies. (dut0 is still handing its reply to rmii_tx until
//      about 950 clocks after a frame starts; a frame that starts before
//      that cuts the reply off.)
//   Counters checked at the end.
//
// Prints "TB_TRADER PASS" or "TB_TRADER FAIL (<n> errors)" at the end.

module tb_trader_mon (
  input  logic       clk,
  input  logic       rst,
  input  logic       tx_en,
  input  logic [1:0] txd
);
  import crc32_pkg::*;

  logic        rx_valid, rx_eof, rx_crs;
  logic [7:0]  rx_data;
  logic [10:0] rx_offset, rx_len;

  rmii_rx u_rx (
    .clk         (clk),
    .rst         (rst),
    .rmii_crs_dv (tx_en),
    .rmii_rxd    (txd),
    .rx_valid    (rx_valid),
    .rx_data     (rx_data),
    .rx_offset   (rx_offset),
    .rx_eof      (rx_eof),
    .rx_len      (rx_len),
    .rx_crs      (rx_crs)
  );

  logic [7:0]  frame [2048];
  int          n      = 0;   // frames received
  int          len    = 0;   // last frame's length, FCS included
  bit          crc_ok = 1'b0;
  logic [31:0] crc    = CRC32_INIT;

  always @(posedge clk) begin
    if (rx_valid) begin
      frame[rx_offset] = rx_data;
      crc = crc32_byte(crc, rx_data);
    end
    if (rx_eof) begin
      len    = rx_len;
      crc_ok = (crc == CRC32_RESIDUE);
      crc    = CRC32_INIT;
      n++;
    end
  end
endmodule

module tb_trader;

  import fix_packets_pkg::*;
  import crc32_pkg::*;

  localparam real CLK_PERIOD = 20.0;  // 50 MHz REF_CLK
  localparam int  RP_LEN     = REPLY_FRAME_LEN;  // FCS included

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #(CLK_PERIOD / 2) clk = ~clk;

  int errors = 0;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      $display("ERROR %0t: %s", $time, msg);
      errors++;
    end
  endtask

  // ---------------------------------------------------------------- generator

  logic       g_valid = 1'b0;
  logic [7:0] g_data  = '0;
  logic       g_last  = 1'b0;
  logic       g_ready, g_busy, g_underrun;
  wire        g_tx_en;
  wire  [1:0] g_txd;

  rmii_tx gen (
    .clk         (clk),
    .rst         (rst),
    .tx_valid    (g_valid),
    .tx_data     (g_data),
    .tx_last     (g_last),
    .tx_ready    (g_ready),
    .tx_busy     (g_busy),
    .tx_underrun (g_underrun),
    .rmii_tx_en  (g_tx_en),
    .rmii_txd    (g_txd)
  );

  logic [7:0] g [2048];

  // Stream g[0 .. n-1] into the generator (as in tb_exchange).
  task automatic g_send(input int n);
    int i;
    i = 0;
    @(negedge clk iff !g_busy);
    g_valid = 1'b1;
    g_data  = g[0];
    g_last  = (n == 1);
    while (i < n) begin
      if (g_ready) begin
        @(negedge clk);
        i++;
        if (i < n) begin
          g_data = g[i];
          g_last = (i == n - 1);
        end
      end else begin
        @(negedge clk);
      end
    end
    g_valid = 1'b0;
    g_last  = 1'b0;
  endtask

  // Market data from MD_FRAME with the given fields. seq_s 5 chars, sym_s 4,
  // px_s 7 ("DDDD.DD").
  task automatic make_md(input string seq_s, input string sym_s,
                         input logic [7:0] side, input string px_s);
    for (int i = 0; i < MD_FRAME_LEN; i++)
      g[i] = MD_FRAME[i];
    for (int j = 0; j < 5; j++) g[66 + j] = seq_s[j];
    for (int j = 0; j < 4; j++) g[75 + j] = sym_s[j];
    g[84] = side;
    for (int j = 0; j < 7; j++) g[90 + j] = px_s[j];
  endtask

  // ---------------------------------------------------------------- DUTs

  logic [1:0]  sel   = 2'd0;
  logic [11:0] k     = 12'd4000;  // $100.00
  logic        clear = 1'b0;

  wire       tx0_en, tx1_en;
  wire [1:0] txd0, txd1;

  logic [31:0] limit0, n_md0, n_buys0, n_ign0, n_sent0, n_cut0;
  logic [31:0] limit1, n_md1, n_buys1, n_ign1, n_sent1, n_cut1;
  logic        buy0, nt0, buy1, nt1;

  trader_core #(.SPECULATIVE_TX(1'b0)) dut0 (
    .clk         (clk),
    .rst         (rst),
    .sel         (sel),
    .k           (k),
    .clear       (clear),
    .rmii_crs_dv (g_tx_en),
    .rmii_rxd    (g_txd),
    .rmii_tx_en  (tx0_en),
    .rmii_txd    (txd0),
    .limit       (limit0),
    .buy         (buy0),
    .no_trade    (nt0),
    .n_md        (n_md0),
    .n_buys      (n_buys0),
    .n_ignored   (n_ign0),
    .n_sent      (n_sent0),
    .n_cut       (n_cut0),
    .rx_crs      (),
    .tx_active   ()
  );

  trader_core #(.SPECULATIVE_TX(1'b1)) dut1 (
    .clk         (clk),
    .rst         (rst),
    .sel         (sel),
    .k           (k),
    .clear       (clear),
    .rmii_crs_dv (g_tx_en),
    .rmii_rxd    (g_txd),
    .rmii_tx_en  (tx1_en),
    .rmii_txd    (txd1),
    .limit       (limit1),
    .buy         (buy1),
    .no_trade    (nt1),
    .n_md        (n_md1),
    .n_buys      (n_buys1),
    .n_ignored   (n_ign1),
    .n_sent      (n_sent1),
    .n_cut       (n_cut1),
    .rx_crs      (),
    .tx_active   ()
  );

  tb_trader_mon mon0 (.clk(clk), .rst(rst), .tx_en(tx0_en), .txd(txd0));
  tb_trader_mon mon1 (.clk(clk), .rst(rst), .tx_en(tx1_en), .txd(txd1));

  // ---------------------------------------------------------------- timing

  // Signals are read at the rising edge, before the edge updates them.
  int cyc = 0;
  int t96 = -1, t0 = -1;
  bit at96_q = 1'b0, tx0_q = 1'b0, tx1_q = 1'b0;

  always @(posedge clk) begin
    cyc++;
    if (at96_q)
      check(dut0.decided && dut1.decided, "decision not registered 1 clock after byte 96");
    at96_q = dut0.rx_valid && dut0.rx_offset == 96;
    if (at96_q)
      t96 = cyc;
    if (dut1.rx_valid && dut1.rx_offset == 0)
      t0 = cyc;
    if (tx0_en && !tx0_q)
      check(cyc - t96 == 2, $sformatf("dut0 TX_EN rose %0d clocks after byte 96, expected 2",
                                      cyc - t96));
    if (tx1_en && !tx1_q)
      check(cyc - t0 == 2, $sformatf("dut1 TX_EN rose %0d clocks after byte 0, expected 2",
                                     cyc - t0));
    tx0_q = tx0_en;
    tx1_q = tx1_en;
  end

  // ---------------------------------------------------------------- expected replies

  logic [7:0] e [256];
  logic [7:0] exp0 [RP_LEN];  // dut0
  logic [7:0] exp1 [RP_LEN];  // dut1: UDP checksum 0

  // One's-complement sum of the UDP pseudo-header and datagram in e[].
  function automatic logic [15:0] e_udp_sum();
    logic [31:0] s;
    int ulen;
    ulen = {e[38], e[39]};
    s = 32'h0011 + ulen;
    for (int i = 26; i < 34; i += 2)
      s += {e[i], e[i + 1]};
    for (int i = 34; i < 34 + ulen; i += 2)
      s += {e[i], (i + 1 < 34 + ulen) ? e[i + 1] : 8'h00};
    while (s >> 16)
      s = (s & 32'hFFFF) + (s >> 16);
    return s[15:0];
  endfunction

  task automatic e_fcs();
    logic [31:0] crc;
    crc = CRC32_INIT;
    for (int i = 0; i < RP_LEN - 4; i++)
      crc = crc32_byte(crc, e[i]);
    crc = ~crc;
    for (int i = 0; i < 4; i++)
      e[RP_LEN - 4 + i] = crc[8*i +: 8];
  endtask

  task automatic make_reply(input string seq_s, input string px_s);
    int sum;
    logic [15:0] c;
    for (int i = 0; i < RP_LEN - 4; i++)
      e[i] = REPLY_FRAME[i];
    for (int j = 0; j < 5; j++) begin
      e[66 + j] = seq_s[j];
      e[75 + j] = seq_s[j];
    end
    for (int j = 0; j < 7; j++)
      e[111 + j] = px_s[j];
    sum = 0;
    for (int i = 42; i <= 118; i++)
      sum += e[i];
    sum = sum % 256;
    e[122] = "0" + sum / 100;
    e[123] = "0" + (sum / 10) % 10;
    e[124] = "0" + sum % 10;

    e[40] = 8'h00;
    e[41] = 8'h00;
    e_fcs();
    for (int i = 0; i < RP_LEN; i++) exp1[i] = e[i];

    c = ~e_udp_sum();
    if (c == 16'h0000) c = 16'hFFFF;
    e[40] = c[15:8];
    e[41] = c[7:0];
    e_fcs();
    for (int i = 0; i < RP_LEN; i++) exp0[i] = e[i];
  endtask

  // ---------------------------------------------------------------- checks

  int tot_frames = 0, tot_md = 0, tot_buys = 0, tot_cut1 = 0;

  task automatic check_reply(input string name, input int dut, input int n0);
    int n, len;
    bit ok;
    n   = dut ? mon1.n : mon0.n;
    len = dut ? mon1.len : mon0.len;
    ok  = dut ? mon1.crc_ok : mon0.crc_ok;
    check(n == n0 + 1, $sformatf("%s: dut%0d sent %0d frames, expected 1", name, dut, n - n0));
    if (n != n0 + 1) return;
    check(len == RP_LEN, $sformatf("%s: dut%0d reply %0d bytes, expected %0d",
                                   name, dut, len, RP_LEN));
    check(ok, $sformatf("%s: dut%0d reply FCS wrong", name, dut));
    for (int i = 0; i < RP_LEN; i++) begin
      logic [7:0] got, want;
      got  = dut ? mon1.frame[i] : mon0.frame[i];
      want = dut ? exp1[i] : exp0[i];
      check(got === want, $sformatf("%s: dut%0d reply byte %0d = %02h, expected %02h",
                                    name, dut, i, got, want));
    end
  endtask

  // Send g[0 .. n-1] and wait until both traders are done with it.
  task automatic send_wait(input int n);
    g_send(n);
    @(negedge clk iff !g_busy);
    repeat (800) @(posedge clk);
    @(posedge clk iff !dut0.tx_busy && !dut1.tx_busy);
    repeat (10) @(posedge clk);
  endtask

  // Market data with the expected outcome.
  task automatic md_test(input string name, input string seq_s, input string sym_s,
                         input logic [7:0] side, input string px_s, input bit exp_buy);
    int a0, a1;
    $display("%s", name);
    a0 = mon0.n;
    a1 = mon1.n;
    make_md(seq_s, sym_s, side, px_s);
    send_wait(MD_FRAME_LEN);
    tot_frames++;
    tot_md++;
    if (exp_buy) begin
      tot_buys++;
      make_reply(seq_s, px_s);
      check_reply(name, 0, a0);
      check_reply(name, 1, a1);
    end else begin
      tot_cut1++;
      check(mon0.n == a0, $sformatf("%s: dut0 sent %0d frames, expected none", name, mon0.n - a0));
      check(mon1.n == a1 + 1 && !mon1.crc_ok,
            $sformatf("%s: dut1 sent %0d frames (FCS ok %0b), expected 1 cut off",
                      name, mon1.n - a1, mon1.crc_ok));
    end
  endtask

  // A frame that is not market data: dut0 ignores it. dut1 has started a
  // reply and cuts it off, unless the very first byte is wrong (cut1 = 0):
  // then the check fails before rmii_tx takes the frame.
  task automatic junk_test(input string name, input int n, input bit cut1);
    int a0, a1;
    $display("%s", name);
    a0 = mon0.n;
    a1 = mon1.n;
    send_wait(n);
    tot_frames++;
    check(mon0.n == a0, $sformatf("%s: dut0 replied", name));
    if (cut1) begin
      tot_cut1++;
      check(mon1.n == a1 + 1 && !mon1.crc_ok,
            $sformatf("%s: dut1 sent %0d frames (FCS ok %0b), expected 1 cut off",
                      name, mon1.n - a1, mon1.crc_ok));
    end else begin
      check(mon1.n == a1, $sformatf("%s: dut1 sent %0d frames, expected none",
                                    name, mon1.n - a1));
    end
  endtask

  // ---------------------------------------------------------------- tests

  initial begin
    repeat (5) @(posedge clk);
    rst = 1'b0;
    repeat (5) @(posedge clk);

    // Test 1: the stored frames.
    $display("Test 1: stored market data, limit $100.00");
    begin
      int a0, a1;
      a0 = mon0.n;
      a1 = mon1.n;
      for (int i = 0; i < MD_FRAME_LEN; i++) g[i] = MD_FRAME[i];
      send_wait(MD_FRAME_LEN);
      tot_frames++;
      tot_md++;
      tot_buys++;
      make_reply("00001", "0100.00");
      for (int i = 0; i < RP_LEN; i++)
        check(exp0[i] == REPLY_FRAME[i],
              $sformatf("testbench reply builder: byte %0d = %02h, REPLY_FRAME has %02h",
                        i, exp0[i], REPLY_FRAME[i]));
      check_reply("Test 1", 0, a0);
      check_reply("Test 1", 1, a1);
      check(limit0 == 32'd1_000_000, $sformatf("limit %0d, expected 1000000", limit0));
    end

    k = 12'd3999;
    md_test("Test 2: limit $99.99", "00001", "AAPL", "1", "0100.00", 1'b0);

    k   = 12'd4095;
    sel = 2'd1;
    md_test("Test 3: ticker MSFT", "00001", "AAPL", "1", "0100.00", 1'b0);
    sel = 2'd0;

    k = 12'd1525;
    md_test("Test 4: seq 00042, $75.25, limit $75.25", "00042", "AAPL", "1", "0075.25", 1'b1);

    k = 12'd1524;
    md_test("Test 5: limit $75.24", "00042", "AAPL", "1", "0075.25", 1'b0);

    k = 12'd4095;
    md_test("Test 6: bid", "00007", "AAPL", "0", "0050.00", 1'b0);

    // Test 7: other frames.
    for (int i = 0; i < 6; i++) g[i] = 8'hff;
    for (int i = 6; i < 12; i++) g[i] = MD_FRAME[i];
    g[12] = 8'h08;
    g[13] = 8'h06;
    for (int i = 14; i < 42; i++) g[i] = 8'h00;
    junk_test("Test 7a: ARP broadcast", 42, 1'b0);

    make_md("00001", "AAPL", "1", "01X0.00");
    junk_test("Test 7b: non-digit in the price", MD_FRAME_LEN, 1'b1);

    make_md("00001", "AAPL", "1", "0100.00");
    junk_test("Test 7c: frame cut short before the price", 80, 1'b1);

    make_md("00001", "AAPL", "1", "0100.00");
    g[37] = 8'h89;  // UDP destination port 5001
    junk_test("Test 7d: destination port 5001", MD_FRAME_LEN, 1'b1);

    // Test 8: switches change during a frame.
    $display("Test 8: switches changed in the middle of a frame");
    begin
      int a0;
      a0 = mon0.n;
      k = 12'd4000;
      make_md("00100", "AAPL", "1", "0100.00");
      fork
        send_wait(MD_FRAME_LEN);
        begin
          @(posedge clk iff dut0.rx_valid && dut0.rx_offset == 50);
          k   = 12'd0;
          sel = 2'd3;
        end
      join
      tot_frames++;
      tot_md++;
      tot_buys++;
      make_reply("00100", "0100.00");
      check_reply("Test 8", 0, a0);
      check(limit0 == 32'd600_000, "limit not updated after the frame");
    end

    // Test 9: three in a row (sel = 3, TSLA, from test 8).
    $display("Test 9: three TSLA frames, 500 clocks apart");
    begin
      int a0, a1;
      a0 = mon0.n;
      a1 = mon1.n;
      k = 12'd0;  // $60.00
      for (int r = 0; r < 3; r++) begin
        make_md("65535", "TSLA", "1", "0001.00");
        g_send(MD_FRAME_LEN);
        repeat (500) @(posedge clk);
      end
      repeat (1500) @(posedge clk);
      tot_frames += 3;
      tot_md     += 3;
      tot_buys   += 3;
      make_reply("65535", "0001.00");
      check(mon0.n == a0 + 3 && mon1.n == a1 + 3,
            $sformatf("Test 9: dut0 sent %0d, dut1 %0d frames, expected 3 each",
                      mon0.n - a0, mon1.n - a1));
      check_reply("Test 9 (last)", 0, a0 + 2);
      check_reply("Test 9 (last)", 1, a1 + 2);
    end

    // Counters.
    check(n_md0 == tot_md && n_md1 == tot_md,
          $sformatf("n_md %0d / %0d, expected %0d", n_md0, n_md1, tot_md));
    check(n_buys0 == tot_buys && n_buys1 == tot_buys,
          $sformatf("n_buys %0d / %0d, expected %0d", n_buys0, n_buys1, tot_buys));
    check(n_ign0 == tot_frames - tot_md && n_ign1 == tot_frames - tot_md,
          $sformatf("n_ignored %0d / %0d, expected %0d", n_ign0, n_ign1, tot_frames - tot_md));
    check(n_sent0 == tot_buys && n_sent1 == tot_buys,
          $sformatf("n_sent %0d / %0d, expected %0d", n_sent0, n_sent1, tot_buys));
    check(n_cut0 == 0, $sformatf("dut0 n_cut %0d, expected 0", n_cut0));
    check(n_cut1 == tot_cut1, $sformatf("dut1 n_cut %0d, expected %0d", n_cut1, tot_cut1));

    @(negedge clk);
    clear = 1'b1;
    @(negedge clk);
    clear = 1'b0;
    check(n_md0 == 0 && n_buys0 == 0 && n_ign0 == 0 && n_sent0 == 0 && n_cut1 == 0,
          "clear did not reset the counters");

    if (errors == 0)
      $display("TB_TRADER PASS");
    else
      $display("TB_TRADER FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #(5ms);
    $display("TB_TRADER FAIL (watchdog)");
    $finish;
  end

endmodule
