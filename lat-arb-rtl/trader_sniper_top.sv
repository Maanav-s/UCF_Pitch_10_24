`timescale 1ns / 1ps
// Board 2: FPGA sniper. LAN8720 on JB. SW[7:0] = extra milliseconds of
// delay after FAIR before the snipe (0 = as fast as possible).

module trader_sniper_top (
  input  logic        rmii_ref_clk,
  input  logic        rmii_crs_dv,
  input  logic [1:0]  rmii_rxd,
  output logic        rmii_tx_en,
  output logic [1:0]  rmii_txd,
  input  logic [15:0] sw,
  output logic [15:0] led
);

  logic clk;
  BUFG u_bufg (.I(rmii_ref_clk), .O(clk));

  logic [4:0] por = '1;
  logic       rst = 1'b1;
  always_ff @(posedge clk) begin
    if (por != 0) por <= por - 5'd1;
    rst <= (por != 0);
  end

  logic [15:0] sw_s;
  xpm_cdc_array_single #(
    .DEST_SYNC_FF(2), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0),
    .SRC_INPUT_REG(0), .WIDTH(16)
  ) u_sw (.src_clk(1'b0), .src_in(sw), .dest_clk(clk), .dest_out(sw_s));

  logic sniping, flattening, last_fill, rx_act, tx_act;
  logic signed [15:0] pos;

  trader_sniper u_tr (
    .clk, .rst, .delay_ms(sw_s[7:0]),
    .rmii_crs_dv, .rmii_rxd, .rmii_tx_en, .rmii_txd,
    .sniping, .flattening, .last_fill, .pos, .rx_act, .tx_act
  );

  always_ff @(posedge clk) begin
    led <= '0;
    led[0] <= sniping;
    led[1] <= flattening;
    led[2] <= last_fill;
    led[3] <= rx_act;
    led[4] <= tx_act;
    led[8] <= pos[0];
    led[9] <= pos[1];
    led[15] <= (pos != 0); // in a long
  end

endmodule
