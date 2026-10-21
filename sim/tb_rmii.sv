`timescale 1ns / 1ps
// Testbench for rmii_tx and rmii_rx.
//
// Loopback: rmii_tx's TX_EN/TXD drive rmii_rx's CRS_DV/RXD directly.
// PHY model: the testbench drives CRS_DV/RXD itself, the way a LAN8720 does
// (00 dibits before the preamble, CRS_DV toggling per nibble at frame end).
//
// Tests
//   1. Loopback of the FIX market-data frame (docs/fix_test_packet.md):
//      every byte comes back, and the FCS matches the Python-computed 4d 73 8b b3.
//      TX_EN rises on the first clock edge after tx_valid.
//   2. Loopback of a 14-byte frame: padded to 60 bytes, valid FCS.
//   3. Two frames back to back: TX_EN low for exactly 12 byte times between them.
//   4. PHY model, FIX frame with FCS, CRS_DV toggling over the last 2 bytes.
//   5. PHY model, false carrier (CRS_DV high, RXD = 10): no bytes, no frame.
//   6. Underrun: tx_valid drops mid-frame, tx_underrun pulses, FCS is bad.
//
// Prints "TB_RMII PASS" or "TB_RMII FAIL (<n> errors)" at the end.

module tb_rmii;

  import crc32_pkg::*;

  parameter bit TX_NEGEDGE = 1'b0;

  localparam real CLK_PERIOD = 20.0;  // 50 MHz REF_CLK

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #(CLK_PERIOD / 2) clk = ~clk;

  // ---------------------------------------------------------------- DUTs

  logic       tx_valid = 1'b0;
  logic [7:0] tx_data  = '0;
  logic       tx_last  = 1'b0;
  logic       tx_ready, tx_busy, tx_underrun;
  logic       tx_en;
  logic [1:0] txd;

  logic       use_phy = 1'b0;
  logic       phy_crs = 1'b0;
  logic [1:0] phy_rxd = '0;

  wire        rx_crs_dv = use_phy ? phy_crs : tx_en;
  wire [1:0]  rx_rxd    = use_phy ? phy_rxd : txd;

  logic        rx_valid, rx_eof, rx_crs;
  logic [7:0]  rx_data;
  logic [10:0] rx_offset, rx_len;

  rmii_tx #(.TX_NEGEDGE(TX_NEGEDGE)) u_tx (
    .clk         (clk),
    .rst         (rst),
    .tx_valid    (tx_valid),
    .tx_data     (tx_data),
    .tx_last     (tx_last),
    .tx_ready    (tx_ready),
    .tx_busy     (tx_busy),
    .tx_underrun (tx_underrun),
    .rmii_tx_en  (tx_en),
    .rmii_txd    (txd)
  );

  rmii_rx u_rx (
    .clk         (clk),
    .rst         (rst),
    .rmii_crs_dv (rx_crs_dv),
    .rmii_rxd    (rx_rxd),
    .rx_valid    (rx_valid),
    .rx_data     (rx_data),
    .rx_offset   (rx_offset),
    .rx_eof      (rx_eof),
    .rx_len      (rx_len),
    .rx_crs      (rx_crs)
  );

  // ---------------------------------------------------------------- data

  // FIX market-data frame from tools/fix_test_packet.py: destination MAC
  // through the end of the UDP payload, without FCS.
  localparam int FIX_LEN = 115;
  logic [7:0] fix_md [FIX_LEN] = '{
    8'h02, 8'h00, 8'h00, 8'h00, 8'h00, 8'h01, 8'h02, 8'h00, 8'h00, 8'h00, 8'h00, 8'h02,
    8'h08, 8'h00, 8'h45, 8'h00, 8'h00, 8'h65, 8'h00, 8'h00, 8'h00, 8'h00, 8'h40, 8'h11,
    8'he5, 8'h34, 8'hc0, 8'ha8, 8'h0a, 8'h02, 8'hc0, 8'ha8, 8'h0a, 8'h01, 8'h13, 8'h88,
    8'h13, 8'h88, 8'h00, 8'h51, 8'hde, 8'h81, 8'h38, 8'h3d, 8'h46, 8'h49, 8'h58, 8'h2e,
    8'h34, 8'h2e, 8'h34, 8'h01, 8'h39, 8'h3d, 8'h30, 8'h35, 8'h30, 8'h01, 8'h33, 8'h35,
    8'h3d, 8'h58, 8'h01, 8'h33, 8'h34, 8'h3d, 8'h30, 8'h30, 8'h30, 8'h30, 8'h31, 8'h01,
    8'h35, 8'h35, 8'h3d, 8'h41, 8'h41, 8'h50, 8'h4c, 8'h01, 8'h32, 8'h36, 8'h39, 8'h3d,
    8'h31, 8'h01, 8'h32, 8'h37, 8'h30, 8'h3d, 8'h30, 8'h31, 8'h30, 8'h30, 8'h2e, 8'h30,
    8'h30, 8'h01, 8'h32, 8'h37, 8'h31, 8'h3d, 8'h30, 8'h30, 8'h31, 8'h30, 8'h30, 8'h01,
    8'h31, 8'h30, 8'h3d, 8'h31, 8'h33, 8'h34, 8'h01
  };
  logic [7:0] fix_fcs [4] = '{8'h4d, 8'h73, 8'h8b, 8'hb3};

  logic [7:0] frame [2048];  // bytes to send
  logic [7:0] got   [2048];  // bytes received, by rx_offset

  // ---------------------------------------------------------------- monitors

  int errors = 0;

  int n_valid  = 0;  // rx_valid strobes since clear_rx
  int n_eof    = 0;  // rx_eof strobes since clear_rx
  int last_len = 0;
  int exp_off  = 0;  // next rx_offset expected in the current frame

  always @(posedge clk) begin
    if (rx_valid) begin
      if (rx_offset != exp_off) begin
        $display("ERROR %0t: rx_offset %0d, expected %0d", $time, rx_offset, exp_off);
        errors++;
      end
      got[rx_offset] = rx_data;
      n_valid++;
      exp_off++;
    end
    if (rx_eof) begin
      last_len = rx_len;
      n_eof++;
      exp_off = 0;
    end
  end

  // Shortest TX_EN-low gap between two frames.
  int  gap = 0;
  int  min_gap = 1 << 30;
  bit  seen_tx = 1'b0;
  always @(posedge clk) begin
    if (tx_en) begin
      if (seen_tx && gap > 0 && gap < min_gap)
        min_gap = gap;
      gap     = 0;
      seen_tx = 1'b1;
    end else if (seen_tx) begin
      gap++;
    end
  end

  bit underrun_seen = 1'b0;
  always @(posedge clk)
    if (tx_underrun) underrun_seen = 1'b1;

  realtime t_valid_rise, t_en_rise;
  always @(posedge tx_valid) t_valid_rise = $realtime;
  always @(posedge tx_en)    t_en_rise    = $realtime;

  // ---------------------------------------------------------------- tasks

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      $display("ERROR %0t: %s", $time, msg);
      errors++;
    end
  endtask

  task automatic clear_rx();
    n_valid  = 0;
    n_eof    = 0;
    exp_off  = 0;
    last_len = 0;
    for (int i = 0; i < 2048; i++) got[i] = 'x;
  endtask

  // Stream frame[0 .. n-1] into rmii_tx. tx_ready is combinational, so it is
  // checked at the falling edge; the byte is taken on the next rising edge.
  task automatic send_frame(input int n);
    int i;
    i = 0;
    @(negedge clk);
    tx_valid = 1'b1;
    tx_data  = frame[0];
    tx_last  = (n == 1);
    while (i < n) begin
      if (tx_ready) begin
        @(negedge clk);
        i++;
        if (i < n) begin
          tx_data = frame[i];
          tx_last = (i == n - 1);
        end
      end else begin
        @(negedge clk);
      end
    end
    tx_valid = 1'b0;
    tx_last  = 1'b0;
  endtask

  // Send frame[0 .. n_ok-1], then drop tx_valid to force an underrun.
  task automatic send_underrun(input int n_ok);
    int i;
    i = 0;
    @(negedge clk);
    tx_valid = 1'b1;
    tx_data  = frame[0];
    while (i < n_ok) begin
      if (tx_ready) begin
        @(negedge clk);
        i++;
        tx_data = frame[i];
      end else begin
        @(negedge clk);
      end
    end
    tx_valid = 1'b0;
  endtask

  task automatic wait_eof(input int max_cycles);
    int c;
    for (c = 0; c < max_cycles && n_eof == 0; c++)
      @(posedge clk);
    check(n_eof == 1, "no rx_eof");
    repeat (2) @(posedge clk);
  endtask

  // Drive frame[0 .. n-1] into rmii_rx as a LAN8720 would: 3 dibits of 00
  // with CRS_DV high, preamble, SFD, data. With toggle_end, CRS_DV is low on
  // the first dibit of each nibble over the last 2 bytes.
  task automatic phy_send(input int n, input bit toggle_end);
    logic [7:0] b;
    use_phy = 1'b1;
    @(negedge clk);
    phy_crs = 1'b1;
    phy_rxd = 2'b00;
    repeat (3) @(negedge clk);
    for (int k = 0; k < 8 + n; k++) begin
      b = (k < 7) ? 8'h55 : (k == 7) ? 8'hD5 : frame[k - 8];
      for (int d = 0; d < 4; d++) begin
        phy_rxd = b[2*d +: 2];
        if (toggle_end && k >= 8 + n - 2)
          phy_crs = d[0];
        @(negedge clk);
      end
    end
    phy_crs = 1'b0;
    phy_rxd = 2'b00;
    repeat (4) @(negedge clk);
    use_phy = 1'b0;
  endtask

  function automatic logic [31:0] crc_of_got(input int n);
    logic [31:0] c;
    c = CRC32_INIT;
    for (int i = 0; i < n; i++)
      c = crc32_byte(c, got[i]);
    return c;
  endfunction

  // ---------------------------------------------------------------- tests

  initial begin
    repeat (5) @(posedge clk);
    rst = 1'b0;
    repeat (5) @(posedge clk);

    // 1. FIX frame loopback.
    $display("Test 1: FIX market-data frame, loopback");
    for (int i = 0; i < FIX_LEN; i++) frame[i] = fix_md[i];
    clear_rx();
    send_frame(FIX_LEN);
    wait_eof(1000);
    check(last_len == FIX_LEN + 4, $sformatf("rx_len %0d, expected %0d", last_len, FIX_LEN + 4));
    for (int i = 0; i < FIX_LEN; i++)
      check(got[i] === fix_md[i], $sformatf("byte %0d = %02h, expected %02h", i, got[i], fix_md[i]));
    for (int i = 0; i < 4; i++)
      check(got[FIX_LEN + i] === fix_fcs[i],
            $sformatf("FCS byte %0d = %02h, expected %02h", i, got[FIX_LEN + i], fix_fcs[i]));
    check(t_en_rise - t_valid_rise == (TX_NEGEDGE ? CLK_PERIOD : CLK_PERIOD / 2),
          $sformatf("TX_EN rose %0.1f ns after tx_valid", t_en_rise - t_valid_rise));
    repeat (60) @(posedge clk);

    // 2. Short frame: padding.
    $display("Test 2: 14-byte frame, padding to 60");
    for (int i = 0; i < 14; i++) frame[i] = fix_md[i];
    clear_rx();
    send_frame(14);
    wait_eof(1000);
    check(last_len == 64, $sformatf("rx_len %0d, expected 64", last_len));
    for (int i = 0; i < 14; i++)
      check(got[i] === fix_md[i], $sformatf("byte %0d = %02h, expected %02h", i, got[i], fix_md[i]));
    for (int i = 14; i < 60; i++)
      check(got[i] === 8'h00, $sformatf("pad byte %0d = %02h", i, got[i]));
    check(crc_of_got(64) === CRC32_RESIDUE, "bad FCS on padded frame");
    repeat (60) @(posedge clk);

    // 3. Back to back: inter-frame gap.
    $display("Test 3: back-to-back frames, inter-frame gap");
    min_gap = 1 << 30;
    clear_rx();
    send_frame(14);
    send_frame(14);
    for (int c = 0; c < 2000 && n_eof < 2; c++) @(posedge clk);
    check(n_eof == 2, $sformatf("%0d frames received, expected 2", n_eof));
    check(min_gap == 48, $sformatf("TX_EN low for %0d clocks between frames, expected 48", min_gap));
    repeat (60) @(posedge clk);

    // 4. PHY model with CRS_DV toggling at frame end.
    $display("Test 4: PHY model, CRS_DV toggling at end of frame");
    for (int i = 0; i < FIX_LEN; i++) frame[i] = fix_md[i];
    for (int i = 0; i < 4; i++) frame[FIX_LEN + i] = fix_fcs[i];
    clear_rx();
    phy_send(FIX_LEN + 4, 1'b1);
    check(n_eof == 1, $sformatf("%0d rx_eof strobes, expected 1", n_eof));
    check(last_len == FIX_LEN + 4, $sformatf("rx_len %0d, expected %0d", last_len, FIX_LEN + 4));
    for (int i = 0; i < FIX_LEN + 4; i++)
      check(got[i] === frame[i], $sformatf("byte %0d = %02h, expected %02h", i, got[i], frame[i]));
    check(crc_of_got(FIX_LEN + 4) === CRC32_RESIDUE, "bad FCS from PHY model");
    repeat (20) @(posedge clk);

    // 5. False carrier.
    $display("Test 5: false carrier");
    clear_rx();
    use_phy = 1'b1;
    @(negedge clk);
    phy_crs = 1'b1;
    phy_rxd = 2'b10;
    repeat (20) @(negedge clk);
    phy_crs = 1'b0;
    phy_rxd = 2'b00;
    repeat (10) @(negedge clk);
    use_phy = 1'b0;
    check(n_valid == 0 && n_eof == 0,
          $sformatf("false carrier gave %0d bytes, %0d frames", n_valid, n_eof));
    repeat (20) @(posedge clk);

    // 6. Underrun.
    $display("Test 6: underrun");
    for (int i = 0; i < FIX_LEN; i++) frame[i] = fix_md[i];
    clear_rx();
    underrun_seen = 1'b0;
    send_underrun(3);
    wait_eof(1000);
    check(underrun_seen, "tx_underrun did not pulse");
    check(last_len == 3 + 4, $sformatf("rx_len %0d, expected 7", last_len));
    check(crc_of_got(last_len) !== CRC32_RESIDUE, "underrun frame has a valid FCS");
    repeat (60) @(posedge clk);

    if (errors == 0)
      $display("TB_RMII PASS");
    else
      $display("TB_RMII FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #1ms;
    $display("TB_RMII FAIL (timeout)");
    $finish;
  end

endmodule
