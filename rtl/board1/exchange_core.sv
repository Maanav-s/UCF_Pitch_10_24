`timescale 1ns / 1ps
// Exchange core: sends the stored FIX market-data frame over RMII and times
// the round trip to the end of the trader's reply. All logic on clk_rmii
// (50 MHz), so 1 tick = 20 ns.
//
// Frames come from fix_packets_pkg (tools/fix_test_packet.py --sv):
//   MD_FRAME     sent as is; rmii_tx adds preamble and FCS.
//   REPLY_FRAME  what a reply must look like.
//
// Latency (lat_*): clock edges from the edge that drives the first preamble
// dibit of the market data onto TXD, to the edge that samples the last dibit
// of the reply (its last FCS dibit) on RXD. Measured with latency_timer, then
// the fixed RX_EOF_LAT clocks that rmii_rx takes to report the frame end are
// subtracted. The PHYs' own delays and the cable are included.
//
// Matching a reply (the timer stops only on a match):
//   - length REPLY_FRAME_LEN bytes, FCS included, and a correct FCS;
//   - every byte equal to REPLY_FRAME, except, when EXACT_MATCH = 0, the
//     fields an OS network stack fills in its own way: source MAC (a laptop
//     keeps its own), IPv4 ID / flags / TTL / header checksum, UDP checksum,
//     and the FCS bytes (the CRC check covers them).
//   Other frames (ARP, IPv6, a wrong reply) are counted in n_other and ignored.
//
// Control:
//   send       pulse: send the market data once, when idle.
//   auto_send  level: send again GAP_CLKS after each reply or timeout.
//   clear      pulse: clear the statistics.

module exchange_core
  import fix_packets_pkg::*;
  import crc32_pkg::*;
#(
  parameter int TIMEOUT_CLKS = 500_000,  // 10 ms
  parameter int GAP_CLKS     = 50_000,   // 1 ms between automatic sends
  parameter bit EXACT_MATCH  = 1'b0,
  parameter bit TX_NEGEDGE   = 1'b0
) (
  input  logic        clk,
  input  logic        rst,

  input  logic        send,
  input  logic        auto_send,
  input  logic        clear,

  input  logic        rmii_crs_dv,
  input  logic [1:0]  rmii_rxd,
  output logic        rmii_tx_en,
  output logic [1:0]  rmii_txd,

  output logic        waiting,       // timer running: sent, no reply yet
  output logic        lat_valid,     // pulse: lat_last updated
  output logic [31:0] lat_last,      // ticks
  output logic [31:0] lat_min,       // 0xFFFFFFFF until the first reply
  output logic [31:0] lat_max,
  output logic [31:0] n_replies,
  output logic [31:0] n_timeouts,
  output logic [31:0] n_other,       // received frames that are not the reply
  output logic [31:0] n_stale,       // matching replies with no send pending
  output logic        last_ok,       // last send got its reply
  output logic        last_timeout,  // last send timed out
  output logic        rx_crs,        // CRS_DV, for an activity LED
  output logic        tx_active      // transmitting, for an activity LED
);

  // rmii_rx raises rx_eof 4 edges after the edge that samples a frame's last
  // dibit: 1 for its input register, 1 to output the last byte, 2 to see
  // CRS_DV low twice.
  localparam int RX_EOF_LAT = 4;

  // ---------------------------------------------------------------- RMII

  logic        tx_valid, tx_last, tx_ready, tx_busy, tx_underrun;
  logic [7:0]  tx_data;

  logic        rx_valid, rx_eof;
  logic [7:0]  rx_data;
  logic [10:0] rx_offset, rx_len;

  rmii_tx #(.TX_NEGEDGE(TX_NEGEDGE)) u_tx (
    .clk         (clk),
    .rst         (rst),
    .tx_valid    (tx_valid),
    .tx_data     (tx_data),
    .tx_last     (tx_last),
    .tx_ready    (tx_ready),
    .tx_busy     (tx_busy),
    .tx_underrun (tx_underrun),
    .rmii_tx_en  (rmii_tx_en),
    .rmii_txd    (rmii_txd)
  );

  rmii_rx u_rx (
    .clk         (clk),
    .rst         (rst),
    .rmii_crs_dv (rmii_crs_dv),
    .rmii_rxd    (rmii_rxd),
    .rx_valid    (rx_valid),
    .rx_data     (rx_data),
    .rx_offset   (rx_offset),
    .rx_eof      (rx_eof),
    .rx_len      (rx_len),
    .rx_crs      (rx_crs)
  );

  // ---------------------------------------------------------------- send

  typedef enum logic [1:0] {S_IDLE, S_SEND, S_WAIT, S_GAP} state_t;

  state_t      state;
  logic [10:0] idx;      // next MD_FRAME byte to hand to rmii_tx
  logic [31:0] gap_cnt;

  assign tx_valid = (state == S_SEND);
  assign tx_data  = MD_FRAME[idx < MD_FRAME_LEN ? idx : 11'd0];
  assign tx_last  = (idx == 11'(MD_FRAME_LEN - 1));

  // rmii_tx starts a frame on the edge where it sees tx_valid while idle, and
  // that edge drives the first preamble dibit.
  wire t_start = tx_valid && !tx_busy;

  logic t_running, t_done, t_timeout;
  logic [31:0] t_ticks;

  always_ff @(posedge clk) begin
    if (rst) begin
      state   <= S_IDLE;
      idx     <= '0;
      gap_cnt <= '0;
    end else begin
      case (state)
        S_IDLE:
          if (send || auto_send) begin
            idx   <= '0;
            state <= S_SEND;
          end

        S_SEND:
          if (tx_ready) begin
            idx <= idx + 11'd1;
            if (tx_last)
              state <= S_WAIT;
          end

        // The timer runs independently of this state, so a reply that ends
        // before the last market-data byte is handed over is still timed.
        S_WAIT:
          if (!t_running) begin
            gap_cnt <= '0;
            state   <= S_GAP;
          end

        S_GAP:
          if (gap_cnt >= 32'(GAP_CLKS - 1))
            state <= S_IDLE;
          else
            gap_cnt <= gap_cnt + 32'd1;

        default: state <= S_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- receive

  // Byte offsets in REPLY_FRAME that must match.
  function automatic bit checked(input logic [10:0] off);
    if (EXACT_MATCH)                 return 1'b1;
    if (off >= 6   && off <= 11)     return 1'b0;  // source MAC
    if (off >= 18  && off <= 22)     return 1'b0;  // IPv4 ID, flags/fragment, TTL
    if (off == 24  || off == 25)     return 1'b0;  // IPv4 header checksum
    if (off == 40  || off == 41)     return 1'b0;  // UDP checksum
    if (off >= REPLY_FRAME_LEN - 4)  return 1'b0;  // FCS: checked by CRC
    return 1'b1;
  endfunction

  logic        mismatch;  // current frame differs from REPLY_FRAME
  logic [31:0] rx_crc;    // CRC over the current frame, FCS included

  always_ff @(posedge clk) begin
    if (rst || rx_eof) begin
      mismatch <= 1'b0;
      rx_crc   <= CRC32_INIT;
    end else if (rx_valid) begin
      rx_crc <= crc32_byte(rx_crc, rx_data);
      if (rx_offset >= 11'(REPLY_FRAME_LEN))
        mismatch <= 1'b1;
      else if (checked(rx_offset) && rx_data != REPLY_FRAME[rx_offset])
        mismatch <= 1'b1;
    end
  end

  wire reply_ok = rx_eof && !mismatch && rx_len == 11'(REPLY_FRAME_LEN)
                  && rx_crc == CRC32_RESIDUE;

  // ---------------------------------------------------------------- timer

  latency_timer #(.W(32), .TIMEOUT(TIMEOUT_CLKS)) u_timer (
    .clk     (clk),
    .rst     (rst),
    .start   (t_start),
    .stop    (reply_ok),
    .running (t_running),
    .done    (t_done),
    .timeout (t_timeout),
    .ticks   (t_ticks)
  );

  assign waiting   = t_running;
  assign tx_active = tx_busy;

  // ---------------------------------------------------------------- stats

  wire [31:0] lat = t_ticks - 32'(RX_EOF_LAT);

  always_ff @(posedge clk) begin
    lat_valid <= 1'b0;
    if (rst || clear) begin
      lat_last     <= '0;
      lat_min      <= '1;
      lat_max      <= '0;
      n_replies    <= '0;
      n_timeouts   <= '0;
      n_other      <= '0;
      n_stale      <= '0;
      last_ok      <= 1'b0;
      last_timeout <= 1'b0;
    end else begin
      if (t_start) begin
        last_ok      <= 1'b0;
        last_timeout <= 1'b0;
      end
      if (t_done) begin
        lat_valid <= 1'b1;
        lat_last  <= lat;
        if (lat < lat_min) lat_min <= lat;
        if (lat > lat_max) lat_max <= lat;
        n_replies <= n_replies + 32'd1;
        last_ok   <= 1'b1;
      end
      if (t_timeout) begin
        n_timeouts   <= n_timeouts + 32'd1;
        last_timeout <= 1'b1;
      end
      if (rx_eof && !reply_ok)
        n_other <= n_other + 32'd1;
      if (reply_ok && !t_running)
        n_stale <= n_stale + 32'd1;
    end
  end

endmodule
