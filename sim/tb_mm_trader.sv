`timescale 1ns / 1ps
// Testbench for mm_trader against the Python strategy (tools/mm_vectors.py:
// sim/mm/tr_*.mem, cut from mm_model.demo()).
//
// The trader (half-spread $2, quoting on) is fed every frame the FPGA
// receives in the demo, in order, and every order and cancel it sends must
// be byte-exact (FCS included) the frame the Python MarketMaker sends at
// that point. The action list interleaves them as they happen: an AAPL
// print, then the trader's burst, then the exchange's reports.
//
// Also checked: the trader starts transmitting (TX_EN) a fixed number of
// clocks after the rx_valid strobe of frame offset 96 of an AAPL print
// that leads to an order (see mm_trader for the number).
//
// Prints "TB_MM_TRADER PASS" or "TB_MM_TRADER FAIL (<n> errors)".

module tb_mm_trader
  import mm_fix_pkg::*;
  import mm_pkg::*;
#(
  parameter string VEC_DIR = "../../../../sim/mm"
) ();
  localparam int STRIDE = 160;
  localparam int MAXA   = 512;
  localparam int MAXF   = 128;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #10 clk = ~clk;

  int errors = 0;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      $display("ERROR %0t: %s", $time, msg);
      errors++;
    end
  endtask

  // ---------------------------------------------------------------- vectors

  logic [31:0] actions [0:MAXA-1];
  logic [7:0]  frames  [0:STRIDE*MAXF-1];
  logic [7:0]  lens    [0:MAXF-1];

  initial begin
    for (int i = 0; i < MAXA; i++) actions[i] = 32'hFF000000;
    $readmemh({VEC_DIR, "/tr_actions.mem"}, actions);
    $readmemh({VEC_DIR, "/tr_frames.mem"}, frames);
    $readmemh({VEC_DIR, "/tr_len.mem"}, lens);
  end

  // ---------------------------------------------------------------- DUT

  logic        crs_dv;
  logic [1:0]  rxd;
  logic        tx_en;
  logic [1:0]  txd;
  logic        clear = 1'b0;
  logic        buy, sell, quote_sent;
  logic [31:0] n_md, n_buys, n_sells, n_fills, n_ignored;

  mm_trader dut (
    .clk                 (clk),
    .rst                 (rst),
    .clear               (clear),
    .half_spread_dollars (4'd2),
    .quoting             (1'b1),
    .rmii_crs_dv         (crs_dv),
    .rmii_rxd            (rxd),
    .rmii_tx_en          (tx_en),
    .rmii_txd            (txd),
    .buy                 (buy),
    .sell                (sell),
    .quote_sent          (quote_sent),
    .n_md                (n_md),
    .n_buys              (n_buys),
    .n_sells             (n_sells),
    .n_fills             (n_fills),
    .n_ignored           (n_ignored),
    .rx_crs              (),
    .tx_active           ()
  );

  mm_tb_port #(.MAXF(MAXF), .STRIDE(STRIDE)) port (
    .clk        (clk),
    .dut_tx_en  (tx_en),
    .dut_txd    (txd),
    .dut_crs_dv (crs_dv),
    .dut_rxd    (rxd)
  );

  // ---------------------------------------------------------------- decision latency

  // Clock edges from the one that samples the DUT's rx_valid strobe of frame
  // offset 96 to the one that samples TX_EN high for the first time.
  int   t96 = -1;
  int   lat_min = 1 << 30, lat_max = 0;
  int   cyc = 0;
  logic tx_en_q = 1'b0;
  always @(posedge clk) begin
    cyc++;
    if (dut.u_rx.rx_valid && dut.u_rx.rx_offset == 96)
      t96 = cyc;
    if (tx_en && !tx_en_q && t96 >= 0 && cyc - t96 < 50) begin
      if (cyc - t96 < lat_min) lat_min = cyc - t96;
      if (cyc - t96 > lat_max) lat_max = cyc - t96;
    end
    tx_en_q = tx_en;
  end

  // ---------------------------------------------------------------- run

  logic [7:0] fr [0:STRIDE-1];
  int n_read = 0;

  task automatic load(input int idx);
    for (int k = 0; k < STRIDE; k++) fr[k] = frames[STRIDE*idx + k];
  endtask

  task automatic expect_frame(input int idx);
    int to;
    to = 0;
    while (port.n_cap <= n_read && to < 20000) begin
      @(posedge clk);
      to++;
    end
    if (port.n_cap <= n_read) begin
      check(1'b0, $sformatf("expected frame %0d: nothing sent", idx));
      return;
    end
    check(port.cap_len[n_read] == lens[idx],
          $sformatf("frame %0d: length %0d, expected %0d", idx, port.cap_len[n_read], lens[idx]));
    for (int k = 0; k < lens[idx] && k < STRIDE; k++)
      if (port.cap[n_read][k] !== frames[STRIDE*idx + k]) begin
        check(1'b0, $sformatf("frame %0d byte %0d: %02x, expected %02x", idx, k,
                              port.cap[n_read][k], frames[STRIDE*idx + k]));
        break;
      end
    n_read++;
  endtask

  initial begin
    int kind, prt, idx, n_exp;
    repeat (8) @(posedge clk);
    rst = 1'b0;
    repeat (8) @(posedge clk);
    n_exp = 0;
    for (int a = 0; a < MAXA; a++) begin
      kind = actions[a][31:24];
      prt  = actions[a][23:16];
      idx  = actions[a][15:0];
      case (kind)
        8'd1: begin
          load(idx);
          port.send(fr, lens[idx]);
        end
        8'd2: begin
          expect_frame(idx);
          n_exp++;
        end
        8'd3: begin
          repeat (4000) @(posedge clk);
          check(port.n_cap == n_read, $sformatf("quiet: %0d unexpected frame(s)", port.n_cap - n_read));
        end
        8'hFF: break;
        default: ;
      endcase
    end
    $display("  %0d frames checked; buys %0d, sells %0d, fills %0d, prints %0d, ignored %0d",
             n_exp, n_buys, n_sells, n_fills, n_md, n_ignored);
    $display("  TX_EN sampled high %0d..%0d clock edges after the rx_valid of offset 96", lat_min, lat_max);
    check(n_buys == 2 && n_sells == 3, "pickoff counts");
    check(n_fills == 5, "fills");
    check(n_ignored == 0, "ignored frames");
    check(lat_min == lat_max && lat_min == 8, "TX_EN does not rise a fixed 8 clocks after offset 96");
    if (errors == 0)
      $display("TB_MM_TRADER PASS");
    else
      $display("TB_MM_TRADER FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #(50ms);
    $display("TB_MM_TRADER FAIL (watchdog)");
    $finish;
  end

endmodule
