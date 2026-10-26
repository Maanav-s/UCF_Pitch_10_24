`timescale 1ns / 1ps
// RMII receiver (spec §9). All logic on clk_rmii (50 MHz REF_CLK).
//
// Samples CRS_DV and RXD[1:0] on the rising edge, in IOB registers. Waits for
// the preamble and the 0xD5 start delimiter, then outputs one byte every 4
// clocks, with its offset from the first byte of the destination MAC.
// The FCS is passed through as ordinary bytes and is not checked.
//
// End of frame: CRS_DV low for 2 consecutive clocks. At the end of a frame the
// PHY may toggle CRS_DV once per nibble (low, high, low, high...) while it
// drains data, so a single low clock is not an end. A frame that does not end
// on a byte boundary drops its partial last byte.
//
// Latency: rx_valid for a byte is high in the cycle after the second rising
// edge following that byte's last dibit on the pins (one edge for the IOB
// register, one for the output register).

module rmii_rx (
  input  logic        clk,
  input  logic        rst,

  input  logic        rmii_crs_dv,
  input  logic [1:0]  rmii_rxd,

  output logic        rx_valid,   // one-cycle strobe per byte
  output logic [7:0]  rx_data,
  output logic [10:0] rx_offset,  // 0 = first byte of destination MAC
  output logic        rx_eof,     // one-cycle strobe after the last byte
  output logic [10:0] rx_len,     // bytes in the frame, FCS included; valid with rx_eof
  output logic        rx_crs      // registered CRS_DV, for an activity LED
);

  (* IOB = "TRUE" *) logic       crs_i;
  (* IOB = "TRUE" *) logic [1:0] rxd_i;

  always_ff @(posedge clk) begin
    crs_i <= rmii_crs_dv;
    rxd_i <= rmii_rxd;
  end

  assign rx_crs = crs_i;

  typedef enum logic [1:0] {S_IDLE, S_PRE, S_DATA} state_t;

  state_t      state;
  logic        crs_q;     // crs_i one clock earlier
  logic        pre_seen;  // last dibit was a preamble dibit (01)
  logic [1:0]  dcnt;      // dibit index within the current byte
  logic [5:0]  sh;        // dibits 0-2 of the current byte, dibit 0 lowest
  logic [10:0] cnt;       // bytes received so far

  wire frame_end = !crs_i && !crs_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      state    <= S_IDLE;
      crs_q    <= 1'b0;
      pre_seen <= 1'b0;
      dcnt     <= '0;
      sh       <= '0;
      cnt      <= '0;
      rx_valid <= 1'b0;
      rx_data  <= '0;
      rx_offset<= '0;
      rx_eof   <= 1'b0;
      rx_len   <= '0;
    end else begin
      crs_q    <= crs_i;
      rx_valid <= 1'b0;
      rx_eof   <= 1'b0;

      case (state)
        S_IDLE: begin
          if (crs_i) begin
            state    <= S_PRE;
            pre_seen <= (rxd_i == 2'b01);
          end
        end

        // The PHY may send 00 dibits before the preamble, or 10 dibits for a
        // false carrier. Only a 11 dibit straight after a 01 starts a frame.
        S_PRE: begin
          if (frame_end) begin
            state <= S_IDLE;
          end else if (pre_seen && rxd_i == 2'b11) begin
            state <= S_DATA;
            dcnt  <= '0;
            cnt   <= '0;
          end else begin
            pre_seen <= (rxd_i == 2'b01);
          end
        end

        S_DATA: begin
          if (frame_end) begin
            state  <= S_IDLE;
            rx_eof <= 1'b1;
            rx_len <= cnt;
          end else begin
            dcnt <= dcnt + 2'd1;
            if (dcnt == 2'd3) begin
              rx_data   <= {rxd_i, sh};
              rx_valid  <= 1'b1;
              rx_offset <= cnt;
              cnt       <= cnt + 11'd1;
            end else begin
              sh <= {rxd_i, sh[5:2]};
            end
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
