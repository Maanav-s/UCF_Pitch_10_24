`timescale 1ns / 1ps
// Build one IPv4/UDP frame from a short payload and send it on RMII.
// Destination MAC first, no preamble: rmii_tx adds preamble, pad and FCS.
// UDP checksum is 0. IPv4 checksum is computed from the latched length.

module pkt_tx
  import lat_arb_pkg::*;
#(
  parameter bit TX_NEGEDGE = 1'b0
) (
  input  logic        clk,
  input  logic        rst,

  input  logic        send,
  input  logic [47:0] dst_mac,
  input  logic [31:0] dst_ip,
  input  logic [47:0] src_mac,
  input  logic [31:0] src_ip,
  input  logic [5:0]  pay_len,
  input  logic [7:0]  pay [0:MAX_PAY-1],
  output logic        busy,

  output logic        rmii_tx_en,
  output logic [1:0]  rmii_txd
);

  logic       tx_valid, tx_last, tx_ready, tx_busy, tx_underrun;
  logic [7:0] tx_data;

  rmii_tx #(.TX_NEGEDGE(TX_NEGEDGE)) u_rmii (
    .clk, .rst,
    .tx_valid, .tx_data, .tx_last, .tx_ready, .tx_busy, .tx_underrun,
    .rmii_tx_en, .rmii_txd
  );

  logic [7:0]  hdr [0:41];
  logic [7:0]  body [0:MAX_PAY-1];
  logic [5:0]  plen;
  logic [6:0]  idx;
  logic [6:0]  last_i;
  logic        active;

  // Use pay_len, not the latched plen: plen updates on this same edge.
  wire [15:0] ip_len  = 16'(20 + 8 + pay_len);
  wire [15:0] udp_len = 16'(8 + pay_len);
  wire [15:0] csum    = ip_csum(ip_len, src_ip, dst_ip);

  assign busy     = active || tx_busy;
  assign tx_valid = active;
  assign last_i   = 7'(42 + plen - 1);
  assign tx_last  = active && (idx == last_i);

  always_comb begin
    tx_data = 8'h00;
    if (active) begin
      if (idx < 7'd42)
        tx_data = hdr[idx];
      else if (idx - 7'd42 < 7'(MAX_PAY))
        tx_data = body[idx - 7'd42];
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      active <= 1'b0;
      idx    <= '0;
      plen   <= '0;
    end else if (send && !active && !tx_busy) begin
      plen      <= pay_len;
      body      <= pay;
      hdr[0]    <= dst_mac[47:40]; hdr[1] <= dst_mac[39:32]; hdr[2] <= dst_mac[31:24];
      hdr[3]    <= dst_mac[23:16]; hdr[4] <= dst_mac[15:8];  hdr[5] <= dst_mac[7:0];
      hdr[6]    <= src_mac[47:40]; hdr[7] <= src_mac[39:32]; hdr[8] <= src_mac[31:24];
      hdr[9]    <= src_mac[23:16]; hdr[10]<= src_mac[15:8];  hdr[11]<= src_mac[7:0];
      hdr[12]   <= 8'h08; hdr[13] <= 8'h00;
      hdr[14]   <= 8'h45; hdr[15] <= 8'h00;
      hdr[16]   <= ip_len[15:8]; hdr[17] <= ip_len[7:0];
      hdr[18]   <= 8'h00; hdr[19] <= 8'h00; hdr[20] <= 8'h00; hdr[21] <= 8'h00;
      hdr[22]   <= 8'h40; hdr[23] <= 8'h11;
      hdr[24]   <= csum[15:8]; hdr[25] <= csum[7:0];
      hdr[26]   <= src_ip[31:24]; hdr[27] <= src_ip[23:16];
      hdr[28]   <= src_ip[15:8];  hdr[29] <= src_ip[7:0];
      hdr[30]   <= dst_ip[31:24]; hdr[31] <= dst_ip[23:16];
      hdr[32]   <= dst_ip[15:8];  hdr[33] <= dst_ip[7:0];
      hdr[34]   <= UDP_PORT[15:8]; hdr[35] <= UDP_PORT[7:0];
      hdr[36]   <= UDP_PORT[15:8]; hdr[37] <= UDP_PORT[7:0];
      hdr[38]   <= udp_len[15:8]; hdr[39] <= udp_len[7:0];
      hdr[40]   <= 8'h00; hdr[41] <= 8'h00;
      idx    <= '0;
      active <= 1'b1;
    end else if (active && tx_ready) begin
      if (idx == last_i)
        active <= 1'b0;
      else
        idx <= idx + 7'd1;
    end
  end

endmodule
