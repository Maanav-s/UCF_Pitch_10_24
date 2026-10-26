`timescale 1ns / 1ps
// Clause-22 MDIO master (IEEE 802.3 §22.2.4.5).
//
// One frame per `start`: 32-bit preamble, ST=01, OP (10 read / 01 write),
// PHYAD, REGAD, turnaround, 16 data bits. MDC = clk / CLK_DIV.
//
// Timing within each MDC period (cnt = 0 … CLK_DIV-1):
//   cnt == 0         MDC falls, the master changes MDIO
//   cnt == HALF-1    the master samples MDIO (read data, driven by the PHY
//                    after the previous rising edge)
//   cnt == HALF      MDC rises, the PHY samples MDIO
//
// mdio_i must already be synchronized to clk. The caller builds the
// tri-state buffer: mdio = mdio_oe ? mdio_o : 'z.
module mdio_master #(
    parameter int CLK_DIV = 400           // 100 MHz / 400 = 250 kHz MDC
) (
    input  logic        clk,
    input  logic        rst,
    // Command port
    input  logic        start,            // ignored while busy
    input  logic        write,            // 1 = write, 0 = read
    input  logic [4:0]  phy_addr,
    input  logic [4:0]  reg_addr,
    input  logic [15:0] wdata,
    output logic        busy,
    output logic        done,             // one cycle when the frame ends
    output logic [15:0] rdata,            // valid at done, for reads
    output logic        ack,              // read: PHY drove the 2nd turnaround bit low
    // MDIO pins
    output logic        mdc,
    output logic        mdio_o,
    output logic        mdio_oe,
    input  logic        mdio_i
);
    localparam int HALF = CLK_DIV / 2;

    logic [$clog2(CLK_DIV)-1:0] cnt;
    logic [5:0]                 bitn;     // 64 bits per frame
    logic [63:0]                sh_out;   // MSB goes out first
    logic [63:0]                sh_oe;
    logic [16:0]                rx_sh;    // last 17 samples: TA bit 2, then D15…D0

    assign rdata = rx_sh[15:0];
    assign ack   = ~rx_sh[16];

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            busy    <= 1'b0;
            mdc     <= 1'b0;
            mdio_o  <= 1'b1;
            mdio_oe <= 1'b0;
            cnt     <= '0;
            bitn    <= '0;
            rx_sh   <= '1;
        end else if (!busy) begin
            mdc     <= 1'b0;
            mdio_oe <= 1'b0;
            if (start) begin
                sh_out <= {32'hFFFF_FFFF, 2'b01, write ? 2'b01 : 2'b10, phy_addr, reg_addr,
                           2'b10, write ? wdata : 16'h0000};
                // A read releases MDIO from the first turnaround bit on.
                sh_oe  <= write ? {64{1'b1}} : {{46{1'b1}}, 18'b0};
                busy   <= 1'b1;
                cnt    <= '0;
                bitn   <= '0;
            end
        end else begin
            cnt <= (cnt == CLK_DIV - 1) ? '0 : cnt + 1;
            if (cnt == 0) begin
                mdc     <= 1'b0;
                mdio_o  <= sh_out[63];
                mdio_oe <= sh_oe[63];
            end
            if (cnt == HALF - 1)
                rx_sh <= {rx_sh[15:0], mdio_i};
            if (cnt == HALF)
                mdc <= 1'b1;
            if (cnt == CLK_DIV - 1) begin
                sh_out <= sh_out << 1;
                sh_oe  <= sh_oe << 1;
                bitn   <= bitn + 1;
                if (bitn == 6'd63) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end
endmodule
