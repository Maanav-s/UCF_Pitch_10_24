`timescale 1ns / 1ps
// Parse one IPv4/UDP frame off RMII. pkt_valid pulses when the payload is
// ours (dest MAC, dest IP, protocol 17, dest port 5000). FCS is not checked.

module pkt_rx
  import lat_arb_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  input  logic        rmii_crs_dv,
  input  logic [1:0]  rmii_rxd,
  input  logic [47:0] our_mac,
  input  logic [31:0] our_ip,

  output logic        pkt_valid,
  output logic [5:0]  pay_len,
  output logic [7:0]  pay [0:MAX_PAY-1],
  output logic        rx_crs
);

  logic        rx_valid, rx_eof;
  logic [7:0]  rx_data;
  logic [10:0] rx_offset, rx_len;

  rmii_rx u_rmii (
    .clk, .rst,
    .rmii_crs_dv, .rmii_rxd,
    .rx_valid, .rx_data, .rx_offset, .rx_eof, .rx_len, .rx_crs
  );

  logic        mac_ok, ip_ok, udp_ok, et_ok, proto_ok;
  logic [15:0] udp_len_r;
  logic [5:0]  got;
  logic [7:0]  acc [0:MAX_PAY-1];
  logic [47:0] dst_mac;
  logic [31:0] dst_ip;
  logic [15:0] et, dport;

  always_ff @(posedge clk) begin
    pkt_valid <= 1'b0;
    if (rst) begin
      mac_ok <= 1'b0; ip_ok <= 1'b0; udp_ok <= 1'b0;
      et_ok <= 1'b0; proto_ok <= 1'b0;
      got <= '0;
      udp_len_r <= '0;
    end else if (rx_valid) begin
      unique case (rx_offset)
        11'd0:  dst_mac[47:40] <= rx_data;
        11'd1:  dst_mac[39:32] <= rx_data;
        11'd2:  dst_mac[31:24] <= rx_data;
        11'd3:  dst_mac[23:16] <= rx_data;
        11'd4:  dst_mac[15:8]  <= rx_data;
        11'd5: begin
          dst_mac[7:0] <= rx_data;
          mac_ok <= ({dst_mac[47:8], rx_data} == our_mac);
        end
        11'd12: et[15:8] <= rx_data;
        11'd13: begin
          et[7:0] <= rx_data;
          et_ok <= ({et[15:8], rx_data} == 16'h0800);
        end
        11'd23: proto_ok <= (rx_data == 8'd17);
        11'd30: dst_ip[31:24] <= rx_data;
        11'd31: dst_ip[23:16] <= rx_data;
        11'd32: dst_ip[15:8]  <= rx_data;
        11'd33: begin
          dst_ip[7:0] <= rx_data;
          ip_ok <= ({dst_ip[31:8], rx_data} == our_ip);
        end
        11'd36: dport[15:8] <= rx_data;
        11'd37: begin
          dport[7:0] <= rx_data;
          udp_ok <= ({dport[15:8], rx_data} == 16'(UDP_PORT));
        end
        11'd38: udp_len_r[15:8] <= rx_data;
        11'd39: udp_len_r[7:0]  <= rx_data;
        default: ;
      endcase
      if (rx_offset >= 11'd42 && got < 6'(MAX_PAY)) begin
        acc[got] <= rx_data;
        got <= got + 6'd1;
      end
    end else if (rx_eof) begin
      if (mac_ok && et_ok && proto_ok && ip_ok && udp_ok
          && udp_len_r >= 16'd8 && (udp_len_r - 16'd8) <= 16'(MAX_PAY)
          && got >= 6'(udp_len_r - 16'd8)) begin
        pay       <= acc;
        pay_len   <= 6'(udp_len_r - 16'd8);
        pkt_valid <= 1'b1;
      end
      mac_ok <= 1'b0; ip_ok <= 1'b0; udp_ok <= 1'b0;
      et_ok <= 1'b0; proto_ok <= 1'b0;
      got <= '0;
    end
  end

endmodule
