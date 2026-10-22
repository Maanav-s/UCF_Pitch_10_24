`timescale 1ns / 1ps
// LAN8720 bring-up debug design for board 2. Not part of the run A/B/C demo.
//
// Checks a LAN8720 module that won't link, without a scope:
//   - measures the module's 50 MHz REF_CLK on JB[0];
//   - finds the PHY over MDIO (MDC on JC[0], MDIO on JC[1]) by scanning
//     addresses 0–31 for a PHY ID, then keeps polling its registers;
//   - BTNC forces MODE = 111 (all capable, auto-negotiation) through the
//     special modes register and soft-resets the PHY, which repairs a bad
//     strap without re-powering the module.
// The RMII TX pins are held low. CRS_DV, RXD0 and RXD1 are inputs with
// pull-ups in the XDC, so the FPGA leaves the mode straps at 111.
//
// Self-test: JB[7] outputs a 25 MHz clock (clk / 4). Jumper JB pin 10 to
// JB pin 1 in place of the module's clock and SW = 111 should read 25.00,
// which proves the REF_CLK measurement path independently of the module.
//
// 7-segment display, selected by SW[2:0] ("----" until the PHY answers):
//   000  reg 2  PHY ID 1                 expect 0007
//   001  reg 3  PHY ID 2                 expect C0Fx (LAN8720A: C0F1)
//   010  reg 1  basic status (BMSR)      7809 no link, 782D link up
//   011  reg 0  basic control (BMCR)     3000/3100 = auto-negotiation on
//   100  reg 18 special modes            bits 7:5 = MODE; last two digits E0/E1 when MODE = 111
//   101  reg 31 special control/status   bits 4:2 = speed: 001 10HD, 101 10FD, 010 100HD, 110 100FD
//   110  PHY address                     "Ad01" etc.
//   111  REF_CLK frequency in MHz        expect 50.00 (±0.01: one count)
//
// LEDs:
//   LED0   PHY answers on MDIO
//   LED1   link up (BMSR bit 2)
//   LED2   auto-negotiation complete (BMSR bit 5)
//   LED3   REF_CLK toggling
//   LED4   CRS_DV activity (stretched)
//   LED5   receive data activity (stretched)
//   LED15  a full scan of addresses 0–31 found no PHY
module phy_debug_top #(
    parameter int MDC_DIV         = 400,        // MDC = 100 MHz / 400 = 250 kHz
    parameter int FREQ_WINDOW     = 160_000,    // 1.6 ms: REF_CLK/16 edges counted = MHz × 100
    parameter int DEBOUNCE_CYCLES = 1_000_000,  // 10 ms
    parameter int RESET_WAIT      = 1_000_000   // 10 ms after a soft reset before polling again
) (
    input  logic        clk,
    input  logic [2:0]  sw,
    input  logic        btnC,
    output logic [15:0] led,
    output logic [6:0]  seg,
    output logic        dp,
    output logic [3:0]  an,
    // LAN8720 module on JB, as in spec §9
    input  logic        rmii_ref_clk,           // JB[0]
    input  logic        rmii_crs_dv,            // JB[1]
    input  logic        rmii_rxd0,              // JB[2]
    input  logic        rmii_rxd1,              // JB[3]
    output logic        rmii_tx_en,             // JB[4]
    output logic        rmii_txd0,              // JB[5]
    output logic        rmii_txd1,              // JB[6]
    output logic        selftest_clk,           // JB[7], 25 MHz loopback source
    // Management interface, debug only
    output logic        mdc,                    // JC[0]
    inout  wire         mdio                    // JC[1]
);
    localparam logic [4:0] SEG_DASH = 5'h10;

    assign rmii_tx_en = 1'b0;
    assign rmii_txd0  = 1'b0;
    assign rmii_txd1  = 1'b0;

    logic [1:0] selftest_div = '0;

    always_ff @(posedge clk)
        selftest_div <= selftest_div + 1;

    assign selftest_clk = selftest_div[1];

    // ---------------------------------------------------------------- reset
    logic [3:0] por_cnt = '0;
    logic       rst     = 1'b1;

    always_ff @(posedge clk) begin
        if (por_cnt != '1)
            por_cnt <= por_cnt + 1;
        rst <= (por_cnt != '1);
    end

    // ------------------------------------------------------ switches, button
    logic [2:0] sw_s;
    logic       btn_press;

    xpm_cdc_array_single #(
        .DEST_SYNC_FF  (2),
        .INIT_SYNC_FF  (1),
        .SRC_INPUT_REG (0),
        .WIDTH         (3)
    ) u_sw_sync (
        .src_clk  (1'b0),
        .src_in   (sw),
        .dest_clk (clk),
        .dest_out (sw_s)
    );

    phy_debug_debounce #(.CYCLES(DEBOUNCE_CYCLES)) u_btnc (
        .clk   (clk),
        .btn   (btnC),
        .level (),
        .press (btn_press)
    );

    // -------------------------------------------------- REF_CLK measurement
    // Vivado inserts IBUF -> BUFG on rmii_ref_clk (see the XDC).
    logic [3:0] ref_div  = '0;
    logic       crs_r    = 1'b0;
    logic       rxdata_r = 1'b0;

    always_ff @(posedge rmii_ref_clk) begin
        ref_div  <= ref_div + 1;
        crs_r    <= rmii_crs_dv;
        rxdata_r <= rmii_crs_dv & (rmii_rxd0 | rmii_rxd1);
    end

    logic ref_tick_s, crs_s, rxdata_s;

    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .SRC_INPUT_REG(1)) u_ref_tick_sync (
        .src_clk (rmii_ref_clk), .src_in (ref_div[3]), .dest_clk (clk), .dest_out (ref_tick_s));
    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .SRC_INPUT_REG(1)) u_crs_sync (
        .src_clk (rmii_ref_clk), .src_in (crs_r), .dest_clk (clk), .dest_out (crs_s));
    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .SRC_INPUT_REG(1)) u_rxdata_sync (
        .src_clk (rmii_ref_clk), .src_in (rxdata_r), .dest_clk (clk), .dest_out (rxdata_s));

    // Works on a local copy: Vivado synthesis ignores assignments to a
    // function's input argument (Synth 8-6104), though simulators honor them.
    function automatic logic [15:0] bcd_inc(input logic [15:0] v);
        logic [15:0] r;
        logic        carry;
        r     = v;
        carry = 1'b1;
        for (int d = 0; d < 4; d++) begin
            if (carry) begin
                if (r[4*d +: 4] == 4'd9) begin
                    r[4*d +: 4] = 4'd0;
                end else begin
                    r[4*d +: 4] = r[4*d +: 4] + 1;
                    carry       = 1'b0;
                end
            end
        end
        return r;
    endfunction

    // One rising edge of ref_div[3] every 16 REF_CLK cycles, so the count over
    // 1.6 ms is the frequency in units of 10 kHz, kept in BCD for the display.
    logic                           ref_tick_d  = 1'b0;
    logic [$clog2(FREQ_WINDOW)-1:0] win_cnt     = '0;
    logic [15:0]                    bcd_cnt     = '0;
    logic [15:0]                    ref_mhz_bcd = '0;

    always_ff @(posedge clk) begin
        ref_tick_d <= ref_tick_s;
        if (win_cnt == FREQ_WINDOW - 1) begin
            win_cnt     <= '0;
            ref_mhz_bcd <= bcd_cnt;
            bcd_cnt     <= '0;
        end else begin
            win_cnt <= win_cnt + 1;
            if (ref_tick_s && !ref_tick_d && bcd_cnt != 16'h9999)
                bcd_cnt <= bcd_inc(bcd_cnt);
        end
    end

    // ------------------------------------------------------------------ MDIO
    logic        mdio_o, mdio_oe, mdio_i;
    logic        mdio_start, mdio_write, mdio_done, mdio_ack;
    logic [4:0]  mdio_phy, mdio_reg;
    logic [15:0] mdio_wdata, mdio_rdata;

    assign mdio = mdio_oe ? mdio_o : 1'bz;

    xpm_cdc_single #(.DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .SRC_INPUT_REG(0)) u_mdio_sync (
        .src_clk (1'b0), .src_in (mdio), .dest_clk (clk), .dest_out (mdio_i));

    mdio_master #(.CLK_DIV(MDC_DIV)) u_mdio (
        .clk      (clk),
        .rst      (rst),
        .start    (mdio_start),
        .write    (mdio_write),
        .phy_addr (mdio_phy),
        .reg_addr (mdio_reg),
        .wdata    (mdio_wdata),
        .busy     (),
        .done     (mdio_done),
        .rdata    (mdio_rdata),
        .ack      (mdio_ack),
        .mdc      (mdc),
        .mdio_o   (mdio_o),
        .mdio_oe  (mdio_oe),
        .mdio_i   (mdio_i)
    );

    // Registers polled once the PHY is found, in this order.
    localparam int N_POLL = 6;

    function automatic logic [4:0] poll_reg(input logic [2:0] idx);
        case (idx)
            3'd0:    return 5'd2;
            3'd1:    return 5'd3;
            3'd2:    return 5'd0;
            3'd3:    return 5'd1;
            3'd4:    return 5'd18;
            default: return 5'd31;
        endcase
    endfunction

    typedef enum logic [2:0] {S_SCAN, S_POLL, S_WR_MODE, S_WR_RESET, S_WAIT} state_t;

    state_t      state;
    logic        waiting;          // an MDIO frame is in flight
    logic [4:0]  phy_addr;
    logic        phy_found;
    logic        scan_failed;
    logic        polled_once;      // every polled register has been read at least once
    logic [2:0]  poll_idx;
    logic        force_req;        // BTNC: apply MODE = 111 at the next poll boundary
    logic [$clog2(RESET_WAIT+1)-1:0] wait_cnt;
    logic [15:0] r_bmcr, r_bmsr, r_id1, r_id2, r_smr, r_scsr;

    always_ff @(posedge clk) begin
        mdio_start <= 1'b0;
        if (btn_press)
            force_req <= 1'b1;

        if (rst) begin
            state       <= S_SCAN;
            waiting     <= 1'b0;
            phy_addr    <= '0;
            phy_found   <= 1'b0;
            scan_failed <= 1'b0;
            polled_once <= 1'b0;
            poll_idx    <= '0;
            force_req   <= 1'b0;
            wait_cnt    <= '0;
            {r_bmcr, r_bmsr, r_id1, r_id2, r_smr, r_scsr} <= '0;
        end else if (waiting) begin
            if (mdio_done) begin
                waiting <= 1'b0;
                case (state)
                    S_SCAN: begin
                        if (mdio_ack && mdio_rdata != 16'hFFFF) begin
                            phy_found   <= 1'b1;
                            scan_failed <= 1'b0;
                            r_id1       <= mdio_rdata;
                            poll_idx    <= '0;
                            state       <= S_POLL;
                        end else begin
                            if (phy_addr == 5'd31)
                                scan_failed <= 1'b1;
                            phy_addr <= phy_addr + 1;
                        end
                    end
                    S_POLL: begin
                        if (!mdio_ack) begin
                            // The PHY stopped answering: start over.
                            phy_found   <= 1'b0;
                            polled_once <= 1'b0;
                            phy_addr    <= '0;
                            state       <= S_SCAN;
                        end else begin
                            case (poll_idx)
                                3'd0:    r_id1  <= mdio_rdata;
                                3'd1:    r_id2  <= mdio_rdata;
                                3'd2:    r_bmcr <= mdio_rdata;
                                3'd3:    r_bmsr <= mdio_rdata;
                                3'd4:    r_smr  <= mdio_rdata;
                                default: r_scsr <= mdio_rdata;
                            endcase
                            if (poll_idx == N_POLL - 1) begin
                                poll_idx    <= '0;
                                polled_once <= 1'b1;
                            end else begin
                                poll_idx <= poll_idx + 1;
                            end
                        end
                    end
                    S_WR_MODE:  state <= S_WR_RESET;
                    S_WR_RESET: begin
                        wait_cnt <= '0;
                        state    <= S_WAIT;
                    end
                    default: ;
                endcase
            end
        end else begin
            case (state)
                S_SCAN: begin
                    mdio_start <= 1'b1;
                    mdio_write <= 1'b0;
                    mdio_phy   <= phy_addr;
                    mdio_reg   <= 5'd2;
                    waiting    <= 1'b1;
                end
                S_POLL: begin
                    if (force_req && polled_once && poll_idx == 0) begin
                        force_req <= 1'b0;
                        state     <= S_WR_MODE;
                    end else begin
                        mdio_start <= 1'b1;
                        mdio_write <= 1'b0;
                        mdio_phy   <= phy_addr;
                        mdio_reg   <= poll_reg(poll_idx);
                        waiting    <= 1'b1;
                    end
                end
                S_WR_MODE: begin
                    // Read-modify-write: keep the reserved bits, set MODE = 111.
                    mdio_start <= 1'b1;
                    mdio_write <= 1'b1;
                    mdio_phy   <= phy_addr;
                    mdio_reg   <= 5'd18;
                    mdio_wdata <= {r_smr[15:8], 3'b111, phy_addr};
                    waiting    <= 1'b1;
                end
                S_WR_RESET: begin
                    // BMCR soft reset; the PHY applies the new MODE.
                    mdio_start <= 1'b1;
                    mdio_write <= 1'b1;
                    mdio_phy   <= phy_addr;
                    mdio_reg   <= 5'd0;
                    mdio_wdata <= 16'h8000;
                    waiting    <= 1'b1;
                end
                S_WAIT: begin
                    if (wait_cnt == RESET_WAIT - 1) begin
                        poll_idx    <= '0;
                        polled_once <= 1'b0;
                        state       <= S_POLL;
                    end else begin
                        wait_cnt <= wait_cnt + 1;
                    end
                end
                default: state <= S_SCAN;
            endcase
        end
    end

    // ------------------------------------------------------------- display
    function automatic logic [19:0] hex4(input logic [15:0] v);
        return {1'b0, v[15:12], 1'b0, v[11:8], 1'b0, v[7:4], 1'b0, v[3:0]};
    endfunction

    logic [19:0] digits;
    logic [3:0]  digit_dp;

    always_comb begin
        digit_dp = 4'b0000;
        case (sw_s)
            3'd0: digits = hex4(r_id1);
            3'd1: digits = hex4(r_id2);
            3'd2: digits = hex4(r_bmsr);
            3'd3: digits = hex4(r_bmcr);
            3'd4: digits = hex4(r_smr);
            3'd5: digits = hex4(r_scsr);
            3'd6: digits = hex4({8'hAD, 3'b000, phy_addr});
            default: begin
                digits   = hex4(ref_mhz_bcd);
                digit_dp = 4'b0100;
            end
        endcase
        if (sw_s != 3'd7 && !(phy_found && polled_once))
            digits = {4{SEG_DASH}};
    end

    phy_debug_sevenseg u_sevenseg (
        .clk    (clk),
        .digits (digits),
        .dp     (digit_dp),
        .seg_n  (seg),
        .dp_n   (dp),
        .an_n   (an)
    );

    // ---------------------------------------------------------------- LEDs
    // Activity is stretched to ~84 ms so single frames are visible.
    logic [22:0] crs_hold = '0;
    logic [22:0] rx_hold  = '0;

    always_ff @(posedge clk) begin
        crs_hold <= crs_s    ? '1 : (crs_hold != 0 ? crs_hold - 1 : '0);
        rx_hold  <= rxdata_s ? '1 : (rx_hold  != 0 ? rx_hold  - 1 : '0);
    end

    assign led[0]    = phy_found;
    assign led[1]    = phy_found & polled_once & r_bmsr[2];
    assign led[2]    = phy_found & polled_once & r_bmsr[5];
    assign led[3]    = (ref_mhz_bcd != 16'h0000);
    assign led[4]    = (crs_hold != 0);
    assign led[5]    = (rx_hold != 0);
    assign led[14:6] = '0;
    assign led[15]   = scan_failed;
endmodule
