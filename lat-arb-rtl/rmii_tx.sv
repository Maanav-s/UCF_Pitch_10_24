`timescale 1ns / 1ps
// RMII transmitter (spec §9). All logic on clk_rmii (50 MHz REF_CLK).
//
// The caller streams frame bytes from the destination MAC onwards; this
// module adds the preamble and start delimiter, pads to MIN_FRAME bytes,
// appends the FCS and holds the inter-frame gap. TX_EN and TXD[1:0] change
// once per clock, 2 bits per clock, LSB first within each byte.
//
// Byte stream (valid/ready):
//   - Raising tx_valid starts a frame. TX_EN rises on the next clock edge.
//   - The first byte is taken after the 8 preamble bytes (32 clocks), then one
//     byte every 4 clocks: a byte is taken on a rising edge where
//     tx_valid && tx_ready. tx_ready is high for one clock per byte.
//   - Mark the last byte with tx_last.
//   - If tx_valid is low when tx_ready is high (underrun), the frame is ended
//     at once with a deliberately wrong FCS, so the receiver drops it, and
//     tx_underrun pulses.
//
// TX_NEGEDGE = 1 re-registers TX_EN/TXD on the falling edge, for more setup
// margin at the PHY. It adds half a clock of latency.
//
// Put the output registers in IOBs from the XDC:
//   set_property IOB TRUE [get_ports {rmii_tx_en rmii_txd[*]}]

module rmii_tx #(
  parameter bit TX_NEGEDGE = 1'b0,
  parameter int MIN_FRAME  = 60,  // bytes before the FCS
  parameter int IFG_BYTES  = 12
) (
  input  logic       clk,
  input  logic       rst,

  input  logic       tx_valid,
  input  logic [7:0] tx_data,
  input  logic       tx_last,
  output logic       tx_ready,
  output logic       tx_busy,
  output logic       tx_underrun,

  output logic       rmii_tx_en,
  output logic [1:0] rmii_txd
);

  import crc32_pkg::*;

  typedef enum logic [2:0] {S_IDLE, S_PRE, S_DATA, S_PAD, S_FCS, S_IFG} state_t;

  // State names the byte that will be loaded next.
  state_t      state;
  logic [7:0]  cur;    // byte being sent
  logic [1:0]  dcnt;   // dibit of cur going out next
  logic [10:0] cnt;    // preamble bytes, frame bytes, FCS bytes or IFG clocks
  logic [31:0] crc;
  logic        bad;    // underrun: send a wrong FCS
  logic        en_r;
  logic [1:0]  txd_r;

  wire        byte_end = (dcnt == 2'd3);
  wire [31:0] fcs      = bad ? crc : ~crc;

  assign tx_ready = (state == S_DATA) && byte_end;
  assign tx_busy  = (state != S_IDLE);

  always_ff @(posedge clk) begin
    if (rst) begin
      state       <= S_IDLE;
      cur         <= '0;
      dcnt        <= '0;
      cnt         <= '0;
      crc         <= CRC32_INIT;
      bad         <= 1'b0;
      en_r        <= 1'b0;
      txd_r       <= '0;
      tx_underrun <= 1'b0;
    end else begin
      tx_underrun <= 1'b0;

      if (state != S_IDLE && state != S_IFG) begin
        txd_r <= cur[2*dcnt +: 2];
        dcnt  <= dcnt + 2'd1;
      end

      case (state)
        S_IDLE: begin
          en_r  <= 1'b0;
          txd_r <= '0;
          if (tx_valid) begin
            // First preamble dibit goes out on this edge.
            en_r  <= 1'b1;
            txd_r <= 2'b01;
            cur   <= 8'h55;
            dcnt  <= 2'd1;
            cnt   <= 11'd1;
            crc   <= CRC32_INIT;
            bad   <= 1'b0;
            state <= S_PRE;
          end
        end

        S_PRE: begin
          if (byte_end) begin
            if (cnt == 11'd7) begin
              cur   <= 8'hD5;
              cnt   <= '0;
              state <= S_DATA;
            end else begin
              cur <= 8'h55;
              cnt <= cnt + 11'd1;
            end
          end
        end

        S_DATA: begin
          if (byte_end) begin
            if (tx_valid) begin
              cur <= tx_data;
              crc <= crc32_byte(crc, tx_data);
              if (tx_last && cnt + 11'd1 >= MIN_FRAME) begin
                cnt   <= '0;
                state <= S_FCS;
              end else begin
                cnt <= cnt + 11'd1;
                if (tx_last)
                  state <= S_PAD;
              end
            end else begin
              // Underrun: start a wrong FCS in this byte slot.
              bad         <= 1'b1;
              tx_underrun <= 1'b1;
              cur         <= crc[7:0];
              cnt         <= 11'd1;
              state       <= S_FCS;
            end
          end
        end

        S_PAD: begin
          if (byte_end) begin
            cur <= 8'h00;
            crc <= crc32_byte(crc, 8'h00);
            if (cnt + 11'd1 >= MIN_FRAME) begin
              cnt   <= '0;
              state <= S_FCS;
            end else begin
              cnt <= cnt + 11'd1;
            end
          end
        end

        S_FCS: begin
          if (byte_end) begin
            if (cnt == 11'd4) begin
              // Last FCS dibit goes out on this edge; TX_EN drops on the next.
              cnt   <= '0;
              state <= S_IFG;
            end else begin
              cur <= fcs[8*cnt[1:0] +: 8];
              cnt <= cnt + 11'd1;
            end
          end
        end

        S_IFG: begin
          en_r  <= 1'b0;
          txd_r <= '0;
          if (cnt == 11'(IFG_BYTES*4 - 1))
            state <= S_IDLE;
          else
            cnt <= cnt + 11'd1;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  generate
    if (TX_NEGEDGE) begin : g_negedge
      logic       en_n;
      logic [1:0] txd_n;
      always_ff @(negedge clk) begin
        en_n  <= en_r;
        txd_n <= txd_r;
      end
      assign rmii_tx_en = en_n;
      assign rmii_txd   = txd_n;
    end else begin : g_posedge
      assign rmii_tx_en = en_r;
      assign rmii_txd   = txd_r;
    end
  endgenerate

endmodule
