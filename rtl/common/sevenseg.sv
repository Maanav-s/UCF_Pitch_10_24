`timescale 1ns / 1ps
// Basys3 4-digit 7-segment driver (common anode, all outputs active low).
//
// `digits` holds four 5-bit codes, digit 3 leftmost:
//   5'h00–5'h0F  hex 0–F
//   5'h10        dash
//   5'h11        blank
module sevenseg (
    input  logic        clk,
    input  logic [19:0] digits,
    input  logic [3:0]  dp,               // decimal point per digit, active high
    output logic [6:0]  seg_n,            // {g,f,e,d,c,b,a}
    output logic        dp_n,
    output logic [3:0]  an_n
);
    // Each digit is lit for 2^17 cycles (1.3 ms at 100 MHz).
    logic [18:0] refresh = '0;
    logic [1:0]  sel;
    logic [4:0]  code;

    assign sel  = refresh[18:17];
    assign code = digits[5*sel +: 5];

    always_ff @(posedge clk) begin
        refresh <= refresh + 1;
        an_n    <= ~(4'b0001 << sel);
        dp_n    <= ~dp[sel];
        case (code)
            5'h00: seg_n <= 7'b1000000;
            5'h01: seg_n <= 7'b1111001;
            5'h02: seg_n <= 7'b0100100;
            5'h03: seg_n <= 7'b0110000;
            5'h04: seg_n <= 7'b0011001;
            5'h05: seg_n <= 7'b0010010;
            5'h06: seg_n <= 7'b0000010;
            5'h07: seg_n <= 7'b1111000;
            5'h08: seg_n <= 7'b0000000;
            5'h09: seg_n <= 7'b0010000;
            5'h0A: seg_n <= 7'b0001000;
            5'h0B: seg_n <= 7'b0000011;
            5'h0C: seg_n <= 7'b1000110;
            5'h0D: seg_n <= 7'b0100001;
            5'h0E: seg_n <= 7'b0000110;
            5'h0F: seg_n <= 7'b0001110;
            5'h10: seg_n <= 7'b0111111;
            default: seg_n <= 7'b1111111;
        endcase
    end
endmodule
