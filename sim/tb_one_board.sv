`timescale 1ns / 1ps
// Smoke test for one_board_top: the JB pins (exchange) wired straight to the
// JC pins (trader), TX to RX both ways, with no PHYs in between.
//
// Without PHYs the RMII data cannot cross between two different
// frequencies (a PHY re-times it to its own clock), so both REF_CLKs are
// 50 MHz here, the trader's 5 ns behind the exchange's. The logic itself is
// tested on one clock in tb_trader and tb_e2e; this checks the top level:
// pins, switch and button mapping, LEDs and the display mux.
//
// The debouncers are shortened to 50 clocks with defparam.
//
// Tests
//   1. Trader limit $111.10 (SW[10:2] all on): BTNC sends, the exchange gets
//      the reply, LED1 (reply) and LED9 (trader buy) light. BTNL shows the
//      limit as 111.1.
//   2. Limit $99.90 (k = 399): BTNC sends, no trade, the exchange times out.
//      LED2 (timeout) and LED10 (trader no trade) light. BTNL shows 99.90.
//
// Prints "TB_ONE_BOARD PASS" or "TB_ONE_BOARD FAIL (<n> errors)" at the end.

module tb_one_board;

  localparam real CLK_PERIOD = 20.0;

  logic ex_clk = 1'b0;
  logic tr_clk = 1'b0;
  always #(CLK_PERIOD / 2) ex_clk = ~ex_clk;
  initial begin
    #5;
    forever #(CLK_PERIOD / 2) tr_clk = ~tr_clk;
  end

  int errors = 0;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      $display("ERROR %0t: %s", $time, msg);
      errors++;
    end
  endtask

  logic        btnC = 1'b0, btnU = 1'b0, btnD = 1'b0, btnR = 1'b0, btnL = 1'b0;
  logic [15:0] sw   = '0;
  logic [15:0] led;
  logic [6:0]  seg;
  logic        dp, rs_tx;
  logic [3:0]  an;

  wire       ex_tx_en, tr_tx_en;
  wire [1:0] ex_txd, tr_txd;

  one_board_top dut (
    .ex_ref_clk (ex_clk),
    .ex_crs_dv  (tr_tx_en),
    .ex_rxd     (tr_txd),
    .ex_tx_en   (ex_tx_en),
    .ex_txd     (ex_txd),
    .tr_ref_clk (tr_clk),
    .tr_crs_dv  (ex_tx_en),
    .tr_rxd     (ex_txd),
    .tr_tx_en   (tr_tx_en),
    .tr_txd     (tr_txd),
    .btnC       (btnC),
    .btnU       (btnU),
    .btnD       (btnD),
    .btnR       (btnR),
    .btnL       (btnL),
    .rs_tx      (rs_tx),
    .sw         (sw),
    .led        (led),
    .seg        (seg),
    .dp         (dp),
    .an         (an)
  );

  defparam dut.u_ex.u_db_c.CLKS = 50;
  defparam dut.u_ex.u_db_u.CLKS = 50;
  defparam dut.u_ex.u_db_d.CLKS = 50;
  defparam dut.u_ex.u_db_r.CLKS = 50;
  defparam dut.u_db_u.CLKS      = 50;
  defparam dut.u_db_l.CLKS      = 50;

  task automatic press(ref logic btn);
    btn = 1'b1;
    repeat (200) @(posedge ex_clk);
    btn = 1'b0;
    repeat (200) @(posedge ex_clk);
  endtask

  // Hold BTNL and check the display shows the trader's limit.
  task automatic check_limit(input int val, input logic [3:0] dp_mask, input string name);
    btnL = 1'b1;
    repeat (200) @(posedge tr_clk);
    check(dut.lim_val == val && dut.lim_dp == dp_mask,
          $sformatf("%s: limit display %0d dp %04b, expected %0d dp %04b",
                    name, dut.lim_val, dut.lim_dp, val, dp_mask));
    check(an === dut.tr_an && seg === dut.tr_seg,
          $sformatf("%s: BTNL does not switch the display to the trader", name));
    btnL = 1'b0;
    repeat (200) @(posedge tr_clk);
    check(an === dut.ex_an && seg === dut.ex_seg,
          $sformatf("%s: display not back on the exchange after BTNL", name));
  endtask

  // Press BTNC and wait until the exchange has a reply or a timeout.
  task automatic do_send(input string name);
    int r0, t0;
    r0 = dut.u_ex.u_core.n_replies;
    t0 = dut.u_ex.u_core.n_timeouts;
    press(btnC);
    for (int c = 0; c < 600_000 && dut.u_ex.u_core.n_replies == r0
                                 && dut.u_ex.u_core.n_timeouts == t0; c++)
      @(posedge ex_clk);
    check(dut.u_ex.u_core.n_replies != r0 || dut.u_ex.u_core.n_timeouts != t0,
          $sformatf("%s: neither a reply nor a timeout", name));
    repeat (60_000) @(posedge ex_clk);  // past the exchange's 1 ms gap
  endtask

  initial begin
    repeat (100) @(posedge ex_clk);

    $display("Test 1: limit $111.10, buy");
    sw[12:11] = 2'b00;      // AAPL
    sw[10:2]  = 9'd511;     // $60.00 + 511 * $0.10
    repeat (100) @(posedge ex_clk);
    check_limit(1111, 4'b0010, "Test 1");
    do_send("Test 1");
    check(dut.u_ex.u_core.n_replies == 1 && dut.u_ex.u_core.n_timeouts == 0
          && dut.u_ex.u_core.n_other == 0,
          $sformatf("Test 1: replies %0d, timeouts %0d, other %0d; expected 1, 0, 0",
                    dut.u_ex.u_core.n_replies, dut.u_ex.u_core.n_timeouts,
                    dut.u_ex.u_core.n_other));
    $display("  latency %0d ticks (%0.2f us)", dut.u_ex.u_core.lat_last,
             dut.u_ex.u_core.lat_last * CLK_PERIOD / 1000.0);
    check(led[1] && !led[2], "Test 1: LED1/LED2 wrong");
    check(led[9] && !led[10], "Test 1: LED9/LED10 wrong (expected trader buy)");

    $display("Test 2: limit $99.90, no trade");
    sw[10:2] = 9'd399;
    repeat (100) @(posedge ex_clk);
    check_limit(9990, 4'b0100, "Test 2");
    do_send("Test 2");
    check(dut.u_ex.u_core.n_replies == 1 && dut.u_ex.u_core.n_timeouts == 1,
          $sformatf("Test 2: replies %0d, timeouts %0d; expected 1, 1",
                    dut.u_ex.u_core.n_replies, dut.u_ex.u_core.n_timeouts));
    check(led[2] && !led[1], "Test 2: LED1/LED2 wrong");
    check(led[10], "Test 2: LED10 (trader no trade) off");

    if (errors == 0)
      $display("TB_ONE_BOARD PASS");
    else
      $display("TB_ONE_BOARD FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #(50ms);
    $display("TB_ONE_BOARD FAIL (watchdog)");
    $finish;
  end

endmodule
