`timescale 1ns / 1ps
// Testbench for mm_exchange against the Python matching engine
// (tools/mm_vectors.py: sim/mm/ex_*.mem).
//
// Two mm_tb_port instances play the laptop (port L) and the FPGA trader
// (port F), each on its own 50 MHz PHY clock; the exchange runs on a
// 49.5 MHz clk, so every byte crosses the xpm_fifo_async instances between
// unrelated clocks. The action list presses "next step" for AAPL prints,
// injects orders, cancels, an ARP frame and a bad-FCS frame, and names every
// frame the exchange must send on each port, byte for byte (FCS included).
// Laptop frames carry a foreign source MAC, IPv4 ID/TTL and a UDP checksum.
//
// At the end the event log is dumped over the UART (BAUD raised to 5 Mbaud
// for simulation) and printed; its line count must be events + 2.
//
// Prints "TB_MM_EXCHANGE PASS" or "TB_MM_EXCHANGE FAIL (<n> errors)".

module tb_mm_exchange
  import mm_fix_pkg::*;
  import mm_pkg::*;
#(
  parameter string VEC_DIR = "../../../../sim/mm"
) ();
  localparam int STRIDE = 160;
  localparam int MAXA   = 512;
  localparam int MAXF   = 128;
  localparam int BAUD   = 5_000_000;

  logic clk   = 1'b0;   // exchange, 49.5 MHz
  logic l_clk = 1'b0;   // port L PHY
  logic f_clk = 1'b0;   // port F PHY
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
    $readmemh({VEC_DIR, "/ex_actions.mem"}, actions);
    $readmemh({VEC_DIR, "/ex_frames.mem"}, frames);
    $readmemh({VEC_DIR, "/ex_len.mem"}, lens);
  end

  // ---------------------------------------------------------------- DUT

  logic        next_step = 1'b0, play = 1'b0, clear = 1'b0, dump_start = 1'b0;
  logic        l_crs_dv, f_crs_dv, l_tx_en, f_tx_en;
  logic [1:0]  l_rxd, f_rxd, l_txd, f_txd;
  logic        rs_tx, dump_busy, busy, script_done, play_active, bid_valid, ask_valid;
  logic        log_full, rx_bad_seen, race_valid, f_first;
  logic [31:0] n_steps, n_fills, lat_f, lat_l, gap;

  mm_exchange #(.GAP_CLKS(5000), .BAUD(BAUD)) dut (
    .clk         (clk),
    .rst         (rst),
    .next_step   (next_step),
    .play        (play),
    .clear       (clear),
    .dump_start  (dump_start),
    .label       (2'b01),
    .l_clk       (l_clk),
    .l_crs_dv    (l_crs_dv),
    .l_rxd       (l_rxd),
    .l_tx_en     (l_tx_en),
    .l_txd       (l_txd),
    .l_rx_active (),
    .f_clk       (f_clk),
    .f_crs_dv    (f_crs_dv),
    .f_rxd       (f_rxd),
    .f_tx_en     (f_tx_en),
    .f_txd       (f_txd),
    .f_rx_active (),
    .rs_tx       (rs_tx),
    .dump_busy   (dump_busy),
    .busy        (busy),
    .script_done (script_done),
    .play_active (play_active),
    .bid_valid   (bid_valid),
    .ask_valid   (ask_valid),
    .log_full    (log_full),
    .rx_bad_seen (rx_bad_seen),
    .n_steps     (n_steps),
    .n_fills     (n_fills),
    .race_valid  (race_valid),
    .f_first     (f_first),
    .lat_f       (lat_f),
    .lat_l       (lat_l),
    .gap         (gap)
  );

  mm_tb_port #(.MAXF(MAXF), .STRIDE(STRIDE)) port_l (
    .clk        (l_clk),
    .dut_tx_en  (l_tx_en),
    .dut_txd    (l_txd),
    .dut_crs_dv (l_crs_dv),
    .dut_rxd    (l_rxd)
  );

  mm_tb_port #(.MAXF(MAXF), .STRIDE(STRIDE)) port_f (
    .clk        (f_clk),
    .dut_tx_en  (f_tx_en),
    .dut_txd    (f_txd),
    .dut_crs_dv (f_crs_dv),
    .dut_rxd    (f_rxd)
  );

  // ---------------------------------------------------------------- UART receiver

  localparam int BIT_CLKS = 10;  // 49.5 MHz / 5 Mbaud, rounded as uart_tx does
  string dump_text = "";
  int    dump_lines = 0;

  initial begin
    logic [7:0] ch;
    forever begin
      @(negedge rs_tx);
      repeat (BIT_CLKS + BIT_CLKS / 2) @(posedge clk);
      for (int b = 0; b < 8; b++) begin
        ch[b] = rs_tx;
        repeat (BIT_CLKS) @(posedge clk);
      end
      dump_text = {dump_text, string'(ch)};
      if (ch == 8'h0A) dump_lines++;
    end
  end

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
          if (prt) port_f.send(fr, lens[idx]);
          else     port_l.send(fr, lens[idx]);
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
    $display("  %0d expectations checked; steps %0d, fills %0d, bad frames seen %0d",
             n_exp, n_steps, n_fills, rx_bad_seen);
    check(n_steps == 3, "steps");
    check(n_fills == 2, "fills");
    check(rx_bad_seen, "the ARP and bad-FCS frames were not counted");
    check(race_valid, "race statistics not valid");
    $display("  last print: FPGA %0d clocks, laptop %0d clocks, F first %0d, gap %0d",
             lat_f, lat_l, f_first, gap);

    // Dump
    @(negedge clk);
    dump_start = 1'b1;
    @(negedge clk);
    dump_start = 1'b0;
    repeat (10) @(posedge clk);
    @(posedge clk iff !dump_busy);
    repeat (200) @(posedge clk);
    $display("---- UART dump ----\n%s-------------------", dump_text);
    check(dump_lines == dut.n_events + 2,
          $sformatf("dump has %0d lines, log has %0d events", dump_lines, dut.n_events));
    check(dump_text.substr(0, 10) == "# mm label=", "dump header");

    if (errors == 0)
      $display("TB_MM_EXCHANGE PASS");
    else
      $display("TB_MM_EXCHANGE FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #(200ms);
    $display("TB_MM_EXCHANGE FAIL (watchdog)");
    $finish;
  end

endmodule
