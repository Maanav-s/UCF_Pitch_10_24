`timescale 1ns / 1ps
// Behavioral clause-22 MDIO slave with a LAN8720A-like register file.
// Starts with MODE = 000 straps; a BMCR soft reset applies the MODE field of
// register 18. Read data changes 10 ns after the MDC rising edge.
module mdio_phy_model #(
    parameter logic [4:0] PHY_ADDR = 5'd1
) (
    input  wire mdc,
    inout  wire mdio
);
    logic [15:0] regs [0:31];
    int          soft_resets = 0;
    logic        drive = 1'b0;
    logic        dout  = 1'b1;

    assign mdio = drive ? dout : 1'bz;

    initial begin
        foreach (regs[i]) regs[i] = 16'h0000;
        regs[0]  = 16'h0000;                  // MODE = 000: 10BASE-T half duplex, no autoneg
        regs[1]  = 16'h7809;                  // no link
        regs[2]  = 16'h0007;
        regs[3]  = 16'hC0F1;
        regs[18] = 16'h6000 | PHY_ADDR;       // MODE = 000
        regs[31] = 16'h0004;                  // 10BASE-T half duplex
    end

    int          ones = 0;
    int          bitn = -1;                   // next frame bit after the preamble, -1 = idle
    logic [13:0] hdr;                         // ST, OP, PHYAD, REGAD
    logic [15:0] wdata;
    logic        mine, is_read;

    task automatic write_reg(input logic [4:0] r, input logic [15:0] v);
        if (r == 5'd0 && v[15]) begin
            soft_resets++;
            if (regs[18][7:5] == 3'b111) begin
                regs[0]  = 16'h3000;          // 100 Mb/s, autoneg enabled
                regs[31] = 16'h0018;          // 100BASE-TX full duplex
            end else begin
                regs[0]  = 16'h0000;
            end
        end else if (r != 5'd1 && r != 5'd2 && r != 5'd3) begin
            regs[r] = v;
        end
    endtask

    always @(posedge mdc) begin
        automatic logic s = mdio;
        if (bitn < 0) begin
            if (s === 1'b1) begin
                ones++;
            end else begin
                if (s === 1'b0 && ones >= 32) begin
                    bitn = 1;                 // ST bit 0 just seen
                    hdr  = '0;
                end
                ones = 0;
            end
        end else begin
            if (bitn <= 13)
                hdr = {hdr[12:0], s};
            if (bitn == 13) begin
                mine    = (hdr[13:12] == 2'b01) && (hdr[9:5] == PHY_ADDR);
                is_read = (hdr[11:10] == 2'b10);
            end
            if (bitn >= 16)
                wdata = {wdata[14:0], s};
            if (mine && is_read) begin
                if (bitn == 14) begin         // drive the 2nd turnaround bit low
                    drive <= #10 1'b1;
                    dout  <= #10 1'b0;
                end else if (bitn >= 15 && bitn <= 30) begin
                    dout  <= #10 regs[hdr[4:0]][30 - bitn];
                end
            end
            if (bitn == 31) begin
                drive <= #10 1'b0;
                if (mine && !is_read)
                    write_reg(hdr[4:0], wdata);
                bitn = -1;
                ones = 0;
            end else begin
                bitn++;
            end
        end
    end
endmodule
