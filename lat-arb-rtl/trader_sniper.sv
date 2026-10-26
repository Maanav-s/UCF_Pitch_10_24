`timescale 1ns / 1ps
// FPGA sniper (F). Longs only: never shorts.
// On FAIR, if the resting ask is more than SPREAD ticks below the new fair,
// buy it IOC. After that fill, wait for a BOOK whose bid sits around the
// new fair, then sell it IOC to flatten. Down-jumps are ignored.

module trader_sniper
  import lat_arb_pkg::*;
#(
  parameter int DELAY_DIV  = 1,
  parameter bit TX_NEGEDGE = 1'b0
) (
  input  logic        clk,
  input  logic        rst,

  input  logic [7:0]  delay_ms,     // extra wait after FAIR before the snipe

  input  logic        rmii_crs_dv,
  input  logic [1:0]  rmii_rxd,
  output logic        rmii_tx_en,
  output logic [1:0]  rmii_txd,

  output logic        sniping,
  output logic        flattening,
  output logic        last_fill,
  output logic signed [15:0] pos,
  output logic        rx_act, tx_act
);

  logic        send, busy, got, crs;
  logic [5:0]  plen, rlen;
  logic [7:0]  pay [0:MAX_PAY-1];
  logic [7:0]  rpay [0:MAX_PAY-1];

  pkt_tx #(.TX_NEGEDGE(TX_NEGEDGE)) u_tx (
    .clk, .rst, .send,
    .dst_mac(E_MAC), .dst_ip(E_IP),
    .src_mac(F_MAC), .src_ip(F_IP),
    .pay_len(plen), .pay(pay), .busy,
    .rmii_tx_en, .rmii_txd
  );
  pkt_rx u_rx (
    .clk, .rst, .rmii_crs_dv, .rmii_rxd,
    .our_mac(F_MAC), .our_ip(F_IP),
    .pkt_valid(got), .pay_len(rlen), .pay(rpay), .rx_crs(crs)
  );

  assign rx_act = crs;
  assign tx_act = busy;

  logic [31:0] fv, bid_px, ask_px, avg;
  logic [15:0] bid_sz, ask_sz, seq;
  logic [31:0] oid;
  logic [31:0] dly;
  logic        have_fv, flatten, pend_snipe, pend_flat, last_fill_r;
  logic signed [15:0] pos_r;

  assign pos        = pos_r;
  assign sniping    = pend_snipe;
  assign flattening = flatten;
  assign last_fill  = last_fill_r;

  wire [31:0] delay_clks = (DELAY_DIV <= 1)
      ? (32'(delay_ms) * 32'(CLK_HZ / 1000))
      : (32'(delay_ms) * 32'(CLK_HZ / 1000) / 32'(DELAY_DIV));

  task automatic hdr(input logic [7:0] typ);
    pay[0] = typ; pay[1] = SRC_F; pay[2] = seq[15:8]; pay[3] = seq[7:0];
  endtask

  always_ff @(posedge clk) begin
    send <= 1'b0;
    if (rst) begin
      fv <= FAIR_PX[0]; have_fv <= 1'b0;
      bid_px <= '0; ask_px <= '0; bid_sz <= '0; ask_sz <= '0;
      seq <= '0; oid <= 32'd2; pos_r <= '0; avg <= '0;
      flatten <= 1'b0; pend_snipe <= 1'b0; pend_flat <= 1'b0;
      last_fill_r <= 1'b0; dly <= '0;
    end else begin
      if (dly != 0)
        dly <= dly - 32'd1;

      if (got) begin
        unique case (rpay[0])
          T_FAIR: begin
            fv      <= {rpay[6], rpay[7], rpay[8], rpay[9]};
            have_fv <= 1'b1;
            dly     <= delay_clks;
            pend_snipe <= 1'b1;
          end
          T_BOOK: begin
            bid_px <= {rpay[4], rpay[5], rpay[6], rpay[7]};
            bid_sz <= {rpay[8], rpay[9]};
            ask_px <= {rpay[10], rpay[11], rpay[12], rpay[13]};
            ask_sz <= {rpay[14], rpay[15]};
            if (flatten)
              pend_flat <= 1'b1;
          end
          T_FILL: begin
            last_fill_r <= 1'b1;
            if (flatten) begin
              pos_r   <= '0;
              flatten <= 1'b0;
              avg     <= '0;
            end else begin
              flatten <= 1'b1;
              avg     <= {rpay[8], rpay[9], rpay[10], rpay[11]};
              pos_r   <= pos_r + $signed({rpay[12], rpay[13]});
            end
          end
          T_ACK: if (rpay[8] == ACK_NO_FILL)
            pend_snipe <= 1'b0;
          default: ;
        endcase
      end

      if (!busy && !send) begin
        if (pend_snipe && dly == 0 && have_fv) begin
          if (ask_sz != 0 && fv > ask_px + 32'(SPREAD)) begin
            hdr(T_ORDER);
            {pay[4],pay[5],pay[6],pay[7]} <= oid;
            pay[8]  <= SIDE_B; pay[9] <= TIF_IOC;
            {pay[10],pay[11],pay[12],pay[13]} <= ask_px;
            {pay[14],pay[15]} <= ask_sz;
            plen <= 6'(LEN_ORDER);
            send <= 1'b1;
            seq  <= seq + 16'd1;
            oid  <= oid + 32'd2;
            pend_snipe <= 1'b0;
          end else begin
            pend_snipe <= 1'b0;
          end
        end else if (pend_flat && flatten) begin
          if (pos_r > 0 && bid_sz != 0 && bid_px >= fv - 32'(HALF_SP)) begin
            hdr(T_ORDER);
            {pay[4],pay[5],pay[6],pay[7]} <= oid;
            pay[8]  <= SIDE_S; pay[9] <= TIF_IOC;
            {pay[10],pay[11],pay[12],pay[13]} <= bid_px;
            {pay[14],pay[15]} <= bid_sz;
            plen <= 6'(LEN_ORDER);
            send <= 1'b1;
            seq  <= seq + 16'd1;
            oid  <= oid + 32'd2;
            pend_flat <= 1'b0;
          end
        end
      end
    end
  end

endmodule
