`timescale 1ns / 1ps
// End-to-end testbench: mm_exchange and mm_trader joined by the port F
// RMII wires (as on the board, minus the two PHYs and the cable), the
// laptop played by a mm_tb_port on port L from the Python demo
// (tools/mm_vectors.py: sim/mm/e2e_*.mem, cut from mm_model.demo()).
//
// For each AAPL print the action list expects the frames the exchange must
// send on both ports while the FPGA trader reacts, then injects the laptop's
// late cancels and quotes and expects the exchange's answers. Every frame
// on either port must be byte-exact the model's. The run ends with 5 fills,
// all FPGA against laptop.
//
// Clocks: the exchange 49.5 MHz, port L's PHY 50 MHz, port F's PHY and the
// trader one 50 MHz clock 7 ns away from port L's.
//
// Prints "TB_MM_E2E PASS" or "TB_MM_E2E FAIL (<n> errors)".

module tb_mm_e2e
  import mm_fix_pkg::*;
  import mm_pkg::*;
#(
  parameter string VEC_DIR = "../../../../sim/mm"
) ();
  localparam int STRIDE = 160;
  localparam int MAXA   = 512;
  localparam int MAXF   = 128;

  logic clk   = 1'b0;   // exchange
  logic l_clk = 1'b0;   // port L PHY (laptop)
  logic f_clk = 1'b0;   // port F PHY and the trader
  logic rst   = 1'b1;
  always #10.1 clk = ~clk;
  always #10   l_clk = ~l_clk;
  initial begin
    #7;
    forever #10 f_clk = ~f_clk;
  end

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
    $readmemh({VEC_DIR, "/e2e_actions.mem"}, actions);
    $readmemh({VEC_DIR, "/e2e_frames.mem"}, frames);
    $readmemh({VEC_DIR, "/e2e_len.mem"}, lens);
  end

  // ---------------------------------------------------------------- DUTs

  logic        next_step = 1'b0;
  logic        l_crs_dv, l_tx_en, f_tx_en, t_tx_en;
  logic [1:0]  l_rxd, l_txd, f_txd, t_txd;
  logic        rs_tx, busy, race_valid, f_first;
  logic [31:0] n_steps, n_fills, lat_f, lat_l, gap;

  mm_exchange #(.GAP_CLKS(5000)) ex (
    .clk         (clk),
    .rst         (rst),
    .next_step   (next_step),
    .play        (1'b0),
    .clear       (1'b0),
    .dump_start  (1'b0),
    .label       (2'b00),
    .l_clk       (l_clk),
    .l_crs_dv    (l_crs_dv),
    .l_rxd       (l_rxd),
    .l_tx_en     (l_tx_en),
    .l_txd       (l_txd),
    .l_rx_active (),
    .f_clk       (f_clk),
    .f_crs_dv    (t_tx_en),
    .f_rxd       (t_txd),
    .f_tx_en     (f_tx_en),
    .f_txd       (f_txd),
    .f_rx_active (),
    .rs_tx       (rs_tx),
    .dump_busy   (),
    .busy        (busy),
    .script_done (),
    .play_active (),
    .bid_valid   (),
    .ask_valid   (),
    .log_full    (),
    .rx_bad_seen (),
    .n_steps     (n_steps),
    .n_fills     (n_fills),
    .race_valid  (race_valid),
    .f_first     (f_first),
    .lat_f       (lat_f),
    .lat_l       (lat_l),
    .gap         (gap)
  );

  logic        tr_rst = 1'b1;
  logic [31:0] tr_buys, tr_sells, tr_fills, tr_ignored;

  mm_trader tr (
    .clk                 (f_clk),
    .rst                 (tr_rst),
    .clear               (1'b0),
    .half_spread_dollars (4'd2),
    .quoting             (1'b1),
    .rmii_crs_dv         (f_tx_en),
    .rmii_rxd            (f_txd),
    .rmii_tx_en          (t_tx_en),
    .rmii_txd            (t_txd),
    .buy                 (),
    .sell                (),
    .quote_sent          (),
    .n_md                (),
    .n_buys              (tr_buys),
    .n_sells             (tr_sells),
    .n_fills             (tr_fills),
    .n_ignored           (tr_ignored),
    .rx_crs              (),
    .tx_active           ()
  );

  mm_tb_port #(.MAXF(MAXF), .STRIDE(STRIDE)) port_l (
    .clk        (l_clk),
    .dut_tx_en  (l_tx_en),
    .dut_txd    (l_txd),
    .dut_crs_dv (l_crs_dv),
    .dut_rxd    (l_rxd)
  );

  // Port F: only captures what the exchange sends to the trader.
  mm_tb_port #(.MAXF(MAXF), .STRIDE(STRIDE)) port_f (
    .clk        (f_clk),
    .dut_tx_en  (f_tx_en),
    .dut_txd    (f_txd),
    .dut_crs_dv (),
    .dut_rxd    ()
  );

  // ---------------------------------------------------------------- run

  logic [7:0] fr [0:STRIDE-1];
  int n_read_l = 0, n_read_f = 0;

  task automatic load(input int idx);
    for (int k = 0; k < STRIDE; k++) fr[k] = frames[STRIDE*idx + k];
  endtask

  task automatic expect_on(input int prt, input int idx);
    int to, n_read;
    to = 0;
    n_read = prt ? n_read_f : n_read_l;
    while (((prt ? port_f.n_cap : port_l.n_cap) <= n_read) && to < 40000) begin
      @(posedge clk);
      to++;
    end
    if ((prt ? port_f.n_cap : port_l.n_cap) <= n_read) begin
      check(1'b0, $sformatf("port %s: expected frame %0d, nothing sent", prt ? "F" : "L", idx));
      return;
    end
    if (prt) begin
      check(port_f.cap_len[n_read] == lens[idx],
            $sformatf("port F frame %0d: length %0d, expected %0d", idx, port_f.cap_len[n_read], lens[idx]));
      for (int k = 0; k < lens[idx]; k++)
        if (port_f.cap[n_read][k] !== frames[STRIDE*idx + k]) begin
          check(1'b0, $sformatf("port F frame %0d byte %0d: %02x, expected %02x", idx, k,
                                port_f.cap[n_read][k], frames[STRIDE*idx + k]));
          break;
        end
      n_read_f++;
    end else begin
      check(port_l.cap_len[n_read] == lens[idx],
            $sformatf("port L frame %0d: length %0d, expected %0d", idx, port_l.cap_len[n_read], lens[idx]));
      for (int k = 0; k < lens[idx]; k++)
        if (port_l.cap[n_read][k] !== frames[STRIDE*idx + k]) begin
          check(1'b0, $sformatf("port L frame %0d byte %0d: %02x, expected %02x", idx, k,
                                port_l.cap[n_read][k], frames[STRIDE*idx + k]));
          break;
        end
      n_read_l++;
    end
  endtask

  initial begin
    int kind, prt, idx, n_exp;
    repeat (20) @(posedge clk);
    rst = 1'b0;
    repeat (8) @(posedge f_clk);
    tr_rst = 1'b0;
    repeat (50) @(posedge clk);
    n_exp = 0;
    for (int a = 0; a < MAXA; a++) begin
      kind = actions[a][31:24];
      prt  = actions[a][23:16];
      idx  = actions[a][15:0];
      case (kind)
        8'd0: begin
          @(negedge clk);
          next_step = 1'b1;
          @(negedge clk);
          next_step = 1'b0;
        end
        8'd1: begin
          load(idx);
          port_l.send(fr, lens[idx]);
        end
        8'd2: begin
          if (prt == 2) begin
            expect_on(0, idx);
            expect_on(1, idx);
          end else begin
            expect_on(prt, idx);
          end
          n_exp++;
        end
        8'd3: begin
          repeat (6000) @(posedge clk);
          check(port_l.n_cap == n_read_l && port_f.n_cap == n_read_f,
                $sformatf("quiet: %0d / %0d unexpected frame(s) on L / F",
                          port_l.n_cap - n_read_l, port_f.n_cap - n_read_f));
        end
        8'hFF: break;
        default: ;
      endcase
    end
    $display("  %0d expectations checked; steps %0d, fills %0d; trader buys %0d sells %0d fills %0d ignored %0d",
             n_exp, n_steps, n_fills, tr_buys, tr_sells, tr_fills, tr_ignored);
    $display("  last print: FPGA %0d clocks (%0.2f us), laptop %0d clocks, F first %0d, gap %0d clocks",
             lat_f, lat_f * 20.2 / 1000.0, lat_l, f_first, gap);
    check(n_steps == 6, "steps");
    check(n_fills == 5, "exchange fills");
    check(tr_fills == 5 && tr_buys == 2 && tr_sells == 3, "trader counts");
    check(tr_ignored == 0, "trader ignored frames");
    check(race_valid && f_first, "FPGA was not first on the last print");
    if (errors == 0)
      $display("TB_MM_E2E PASS");
    else
      $display("TB_MM_E2E FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #(300ms);
    $display("TB_MM_E2E FAIL (watchdog)");
    $finish;
  end

endmodule
