`timescale 1ns / 1ps
// Testbench for phy_debug_top against mdio_phy_model at PHY address 1.
// Checks: address scan, register polling, REF_CLK measurement (50.00 MHz),
// and the BTNC MODE = 111 write followed by a soft reset.
module tb_phy_debug;
    logic clk     = 1'b0;
    logic ref_clk = 1'b0;
    always #5  clk     = ~clk;                // 100 MHz
    always #10 ref_clk = ~ref_clk;            // 50 MHz

    logic [2:0]  sw   = 3'd7;
    logic        btnC = 1'b0;
    wire  [15:0] led;
    wire  [6:0]  seg;
    wire  [3:0]  an;
    wire         dp, mdc, tx_en, txd0, txd1, selftest_clk;
    tri1         mdio;                        // pull-up, as on the board

    phy_debug_top #(
        .MDC_DIV         (20),
        .DEBOUNCE_CYCLES (10),
        .RESET_WAIT      (1000)
    ) dut (
        .clk          (clk),
        .sw           (sw),
        .btnC         (btnC),
        .led          (led),
        .seg          (seg),
        .dp           (dp),
        .an           (an),
        .rmii_ref_clk (ref_clk),
        .rmii_crs_dv  (1'b0),
        .rmii_rxd0    (1'b0),
        .rmii_rxd1    (1'b0),
        .rmii_tx_en   (tx_en),
        .rmii_txd0    (txd0),
        .rmii_txd1    (txd1),
        .selftest_clk (selftest_clk),
        .mdc          (mdc),
        .mdio         (mdio)
    );

    mdio_phy_model #(.PHY_ADDR(5'd1)) phy (
        .mdc  (mdc),
        .mdio (mdio)
    );

    int errors = 0;

    task automatic check(input bit cond, input string msg);
        if (!cond) begin
            errors++;
            $error("FAIL: %s", msg);
        end else begin
            $display("ok:   %s", msg);
        end
    endtask

    initial begin
        wait (dut.phy_found && dut.polled_once);
        @(posedge clk);
        check(dut.phy_addr == 5'd1,     "PHY found at address 1");
        check(!led[15],                 "scan-failed LED off");
        check(led[0],                   "PHY-found LED on");
        check(dut.r_id1  == 16'h0007,   "reg 2 = 0007");
        check(dut.r_id2  == 16'hC0F1,   "reg 3 = C0F1");
        check(dut.r_bmsr == 16'h7809,   "reg 1 = 7809");
        check(dut.r_smr  == 16'h6001,   "reg 18 = 6001 (MODE 000)");

        // Two full measurement windows have passed by 3.3 ms.
        while ($time < 3_300_000) @(posedge clk);
        check(dut.ref_mhz_bcd inside {16'h4999, 16'h5000, 16'h5001}, "REF_CLK reads 50.00 MHz");
        check(led[3],                   "REF_CLK LED on");

        // BTNC: MODE = 111, then soft reset.
        btnC = 1'b1;
        #1000;
        btnC = 1'b0;
        wait (phy.soft_resets == 1);
        check(phy.regs[18] == 16'h60E1, "reg 18 written with MODE 111, address kept");
        wait (!dut.polled_once);              // cleared when polling restarts
        wait (dut.polled_once);
        @(posedge clk);
        check(dut.r_bmcr == 16'h3000,   "reg 0 = 3000 after soft reset");
        check(dut.r_scsr == 16'h0018,   "reg 31 reports 100BASE-TX full duplex");

        if (errors == 0) $display("PASS: tb_phy_debug");
        else             $display("FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #20ms;
        $fatal(1, "timeout");
    end
endmodule
