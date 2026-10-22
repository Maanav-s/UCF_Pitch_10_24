`timescale 1ns / 1ps
// FPGA trader core (board 2, LAN8720 on RMII). Answers the exchange's FIX
// market data (docs/fix_test_packet.md) with a FIX buy order when the
// trading rule holds. All logic on clk_rmii (50 MHz), so 1 clock = 20 ns.
//
// Market data is checked and decoded as it streams out of rmii_rx. The FIX
// fields are fixed width, so every field is at a constant frame offset
// (0 = first byte of the destination MAC):
//   0-65   Ethernet, IPv4, UDP and FIX up to "34=": must equal MD_FRAME,
//          except the source MAC (6-11), IPv4 ID/flags/TTL (18-22), IPv4
//          checksum (24-25) and UDP checksum (40-41). That is: to
//          02:00:00:00:00:01, IPv4/UDP from 192.168.10.2:5000 to
//          192.168.10.1:5000, a 73-byte payload, "8=FIX.4.4|9=050|35=X|34=".
//   66-70  MsgSeqNum: 5 digits, copied into the reply
//   75-78  Symbol: compared with TICKER[sel]
//   84     MDEntryType: '1' (offer) is needed for a buy
//   90-96  MDEntryPx "DDDD.DD": digits, copied into the reply
//   The SOHs and tag text between these fields, and the '.' at 94, must
//   equal MD_FRAME. Bytes after 96 (size, CheckSum) and the FCS are not
//   checked: the decision is made at byte 96.
//
// Rule (spec §5): buy if the frame passed the checks, Symbol == TICKER[sel],
// MDEntryType == '1' and price <= limit, where limit = LIMIT_BASE +
// k * LIMIT_STEP in $0.0001 units. Otherwise no order is sent: FIX has no
// "no trade" reply, and the exchange counts the send as a timeout.
//
// Decision timing: the decision is registered on the clock edge that takes
// in rx_valid for frame offset 96 (the last price byte). So it is valid in
// the cycle after that rx_valid strobe, a fixed 1 clock.
//
// Reply: REPLY_FRAME (the stored buy order; rmii_tx appends the FCS) with
//   40-41    UDP checksum, recomputed (0 = none when SPECULATIVE_TX)
//   66-70    MsgSeqNum (34)  = market data's MsgSeqNum
//   75-79    ClOrdID (11)    = market data's MsgSeqNum
//   111-117  Price (44)      = market data's MDEntryPx
//   122-124  CheckSum (10), recomputed
// The addresses are fixed (spec §3), so the IPv4 header and its checksum
// stay as stored. The patched values come through a short pipeline
// (CK_STAGES clocks after the decision); bytes that need them wait for it.
//
// Transmit start:
//   SPECULATIVE_TX = 0: TX_EN rises 2 clocks after the rx_valid strobe of
//     byte 96 (1 to register the decision, 1 for rmii_tx). The rest of the
//     market-data frame is still arriving: RMII is full duplex.
//   SPECULATIVE_TX = 1: TX_EN rises 2 clocks after the rx_valid strobe of
//     byte 0, before anything about the frame is known. The reply's bytes
//     come out later than the market-data bytes they copy (seq: 15 clocks
//     margin; price and CheckSum: over 90). If the frame fails a check or
//     the rule says no, the reply is cut off with a deliberately wrong FCS
//     (rmii_tx underrun), so the exchange drops it. The UDP checksum is sent
//     as 0 (none), because it goes out before the price is known.
//   In both modes, a byte whose data is not ready yet is not handed over, so
//   a late field can only cut the frame off, never send wrong data.
//
// One frame at a time: a new frame that starts while a reply is still being
// handed to rmii_tx resets the parser, which cuts that reply off.

module trader_core
  import fix_packets_pkg::*;
#(
  parameter bit          SPECULATIVE_TX = 1'b0,
  parameter bit          TX_NEGEDGE     = 1'b0,
  parameter logic [31:0] LIMIT_BASE     = 32'd600_000,  // $60.00
  parameter logic [31:0] LIMIT_STEP     = 32'd100,      // $0.01
  parameter logic [31:0] TICKER0        = "AAPL",
  parameter logic [31:0] TICKER1        = "MSFT",
  parameter logic [31:0] TICKER2        = "NVDA",
  parameter logic [31:0] TICKER3        = "TSLA"
) (
  input  logic        clk,
  input  logic        rst,

  input  logic [1:0]  sel,       // ticker preset; sampled between frames
  input  logic [11:0] k,         // limit step; sampled between frames
  input  logic        clear,     // pulse: clear the counters

  input  logic        rmii_crs_dv,
  input  logic [1:0]  rmii_rxd,
  output logic        rmii_tx_en,
  output logic [1:0]  rmii_txd,

  output logic [31:0] limit,     // limit in use, $0.0001 units
  output logic        buy,       // pulse: decided to buy
  output logic        no_trade,  // pulse: valid market data, rule says no
  output logic [31:0] n_md,      // frames that passed the market-data checks
  output logic [31:0] n_buys,
  output logic [31:0] n_ignored, // other frames
  output logic [31:0] n_sent,    // replies sent in full
  output logic [31:0] n_cut,     // replies cut off with a wrong FCS
  output logic        rx_crs,    // CRS_DV, for an activity LED
  output logic        tx_active  // transmitting, for an activity LED
);

  // Market-data frame offsets
  localparam int MD_SEQ  = 66;
  localparam int MD_SYM  = 75;
  localparam int MD_SIDE = 84;
  localparam int MD_PX   = 90;
  localparam int MD_DOT  = 94;
  localparam int MD_LAST = 96;  // last price byte: the decision is made here

  // Reply frame offsets
  localparam int RP_UDP_CK = 40;
  localparam int RP_SEQ    = 66;
  localparam int RP_CLORD  = 75;
  localparam int RP_PX     = 111;
  localparam int RP_CK     = 122;
  localparam int RP_LEN    = REPLY_FRAME_LEN - 4;  // without the FCS

  localparam int CK_STAGES = 5;  // pipeline from the decision to udp_ck

  // ---------------------------------------------------------------- RMII

  logic        tx_valid, tx_last, tx_ready, tx_busy, tx_underrun;
  logic [7:0]  tx_data;

  logic        rx_valid, rx_eof;
  logic [7:0]  rx_data;
  logic [10:0] rx_offset, rx_len;

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

  assign tx_active = tx_busy;

  // ---------------------------------------------------------------- parser

  // Offsets that must equal MD_FRAME.
  function automatic bit md_checked(input logic [10:0] off);
    if (off >= 6  && off <= 11)                 return 1'b0;  // source MAC
    if (off >= 18 && off <= 22)                 return 1'b0;  // IPv4 ID, flags, TTL
    if (off == 24 || off == 25)                 return 1'b0;  // IPv4 checksum
    if (off == 40 || off == 41)                 return 1'b0;  // UDP checksum
    if (off >= MD_SEQ && off < MD_SEQ + 5)      return 1'b0;
    if (off >= MD_SYM && off < MD_SYM + 4)      return 1'b0;
    if (off == MD_SIDE)                         return 1'b0;
    if (off >= MD_PX && off <= MD_LAST && off != MD_DOT) return 1'b0;
    return 1'b1;
  endfunction

  function automatic bit is_digit(input logic [7:0] b);
    return b >= "0" && b <= "9";
  endfunction

  logic        in_frame;  // between a frame's first byte and its rx_eof
  logic        bad;       // a check failed (before the decision)
  logic        decided;   // the decision for this frame is made
  logic        md_ok;     // ... and the frame is valid market data
  logic        buy_r;     // ... and the rule says buy
  logic        early;     // the frame ended before byte 96
  logic        have_seq;  // MsgSeqNum captured
  logic        sym_ok, side_ok;
  logic [19:0] acc;       // price in cents, from the digits so far
  logic [0:4][7:0] seq;
  logic [0:6][7:0] px;
  logic [31:0] ticker;    // TICKER[sel], taken between frames

  wire        off_seq  = rx_offset >= MD_SEQ && rx_offset < MD_SEQ + 5;
  wire        off_sym  = rx_offset >= MD_SYM && rx_offset < MD_SYM + 4;
  wire        off_px   = rx_offset >= MD_PX  && rx_offset <= MD_LAST;
  wire        off_pxd  = off_px && rx_offset != MD_DOT;
  wire [7:0]  md_byte  = MD_FRAME[rx_offset <= MD_LAST ? rx_offset : 11'd0];
  logic [7:0] sym_byte;

  // Constant part-selects only: a variable part-select of a wide constant
  // crashed Vivado 2025.2 synthesis (see exchange_dump).
  always_comb
    case (2'(rx_offset - 11'(MD_SYM)))
      2'd0:    sym_byte = ticker[31:24];
      2'd1:    sym_byte = ticker[23:16];
      2'd2:    sym_byte = ticker[15:8];
      default: sym_byte = ticker[7:0];
    endcase

  wire byte_bad = (md_checked(rx_offset) && rx_data != md_byte)
                  || ((off_seq || off_pxd) && !is_digit(rx_data));

  // At byte 96: the whole price, in $0.0001 units.
  wire [19:0] acc_next = acc * 20'd10 + 20'(rx_data[3:0]);
  wire [31:0] px_units = 32'(acc_next) * 32'd100;

  wire at_last   = rx_valid && rx_offset == MD_LAST && !decided;
  wire md_ok_now = !bad && !byte_bad;
  wire buy_now   = md_ok_now && sym_ok && side_ok && px_units <= limit;

  always_ff @(posedge clk) begin
    if (rst) begin
      in_frame <= 1'b0;
      bad      <= 1'b0;
      decided  <= 1'b0;
      md_ok    <= 1'b0;
      buy_r    <= 1'b0;
      early    <= 1'b0;
      have_seq <= 1'b0;
      sym_ok   <= 1'b0;
      side_ok  <= 1'b0;
      acc      <= '0;
      seq      <= '0;
      px       <= '0;
      ticker   <= TICKER0;
      limit    <= LIMIT_BASE;
    end else begin
      // Switches are taken only between frames.
      if (!in_frame && !rx_valid) begin
        case (sel)
          2'd0:    ticker <= TICKER0;
          2'd1:    ticker <= TICKER1;
          2'd2:    ticker <= TICKER2;
          default: ticker <= TICKER3;
        endcase
        limit <= LIMIT_BASE + 32'(k) * LIMIT_STEP;
      end

      if (rx_eof) begin
        in_frame <= 1'b0;
        if (!decided)
          early <= 1'b1;
      end

      if (rx_valid) begin
        in_frame <= 1'b1;
        if (rx_offset == 11'd0) begin
          bad      <= byte_bad;
          decided  <= 1'b0;
          md_ok    <= 1'b0;
          buy_r    <= 1'b0;
          early    <= 1'b0;
          have_seq <= 1'b0;
          sym_ok   <= 1'b1;
          side_ok  <= 1'b0;
          acc      <= '0;
        end else if (!decided) begin
          if (byte_bad)
            bad <= 1'b1;
          if (off_seq)
            seq[3'(rx_offset - 11'(MD_SEQ))] <= rx_data;
          if (rx_offset == MD_SEQ + 4)
            have_seq <= 1'b1;
          if (off_sym && rx_data != sym_byte)
            sym_ok <= 1'b0;
          if (rx_offset == MD_SIDE)
            side_ok <= (rx_data == "1");
          if (off_px)
            px[3'(rx_offset - 11'(MD_PX))] <= rx_data;
          if (off_pxd)
            acc <= acc_next;
          if (rx_offset == MD_LAST) begin
            decided <= 1'b1;
            md_ok   <= md_ok_now;
            buy_r   <= buy_now;
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------- reply fields

  // Constant parts of the reply's checksums, from REPLY_FRAME with the
  // patched bytes left out.
  function automatic bit rp_patched(input int i);
    return (i >= RP_SEQ   && i < RP_SEQ + 5)
        || (i >= RP_CLORD && i < RP_CLORD + 5)
        || (i >= RP_PX    && i < RP_PX + 7)
        || (i >= RP_CK    && i < RP_CK + 3)
        || i == RP_UDP_CK || i == RP_UDP_CK + 1;
  endfunction

  // FIX CheckSum: sum of the payload bytes before "10=" (frame 42-118).
  function automatic logic [7:0] fix_base();
    logic [7:0] s;
    s = '0;
    for (int i = 42; i <= RP_CK - 4; i++)
      if (!rp_patched(i))
        s = s + REPLY_FRAME[i];
    return s;
  endfunction

  // UDP checksum: 16-bit words of the pseudo-header (addresses at 26-33,
  // protocol, UDP length), the UDP header and the payload. A byte at an even
  // frame offset is the high byte of its word.
  function automatic logic [31:0] udp_base();
    logic [31:0] s;
    s = 32'h0011 + {16'h0, REPLY_FRAME[38], REPLY_FRAME[39]};
    for (int i = 26; i < RP_LEN; i++)
      if (!rp_patched(i))
        s = s + ((i % 2 == 0) ? {16'h0, REPLY_FRAME[i], 8'h00} : {24'h0, REPLY_FRAME[i]});
    return s;
  endfunction

  localparam logic [7:0]  FIX_BASE = fix_base();
  localparam logic [31:0] UDP_BASE = udp_base();

  // Pipeline from the captured bytes, running every clock. Word positions:
  // seq appears at 66 (even) and 75 (odd), so each digit counts once as a
  // high and once as a low byte; price starts at 111 (odd); CheckSum at 122
  // (even).
  logic [10:0]     seq_sum, px_hi, px_lo;
  logic [7:0]      ck_bin;
  logic [0:2][7:0] ck;
  logic [31:0]     u_sum;
  logic [15:0]     udp_ck;
  logic [CK_STAGES-1:0] rdy_sr;

  wire ck_rdy = rdy_sr[CK_STAGES-1];

  // 8-bit value to 3 ASCII digits.
  function automatic logic [0:2][7:0] to_ascii3(input logic [7:0] v);
    logic [7:0] r;
    logic [3:0] h, t, u;
    h = (v >= 8'd200) ? 4'd2 : (v >= 8'd100) ? 4'd1 : 4'd0;
    r = v - 8'(h) * 8'd100;
    t = 4'((16'(r) * 16'd205) >> 11);  // r / 10, exact for r < 1029
    u = 4'(r - 8'(t) * 8'd10);
    return {8'h30 | 8'(h), 8'h30 | 8'(t), 8'h30 | 8'(u)};
  endfunction

  logic [16:0] u_f, u_fold;

  always_ff @(posedge clk) begin
    // stage 1
    seq_sum <= 11'(seq[0]) + 11'(seq[1]) + 11'(seq[2]) + 11'(seq[3]) + 11'(seq[4]);
    px_hi   <= 11'(px[1]) + 11'(px[3]) + 11'(px[5]);
    px_lo   <= 11'(px[0]) + 11'(px[2]) + 11'(px[4]) + 11'(px[6]);
    // stage 2
    ck_bin  <= FIX_BASE + 8'(seq_sum << 1) + 8'(px_hi) + 8'(px_lo);
    // stage 3
    ck      <= to_ascii3(ck_bin);
    // stage 4
    u_sum   <= UDP_BASE + 32'(seq_sum) * 32'd257
               + ((32'(px_hi) + 32'(ck[0]) + 32'(ck[2])) << 8)
               + 32'(px_lo) + 32'(ck[1]);
    // stage 5: fold and invert (0 is sent as 0xFFFF)
    udp_ck  <= (~u_fold[15:0] == 16'h0000) ? 16'hFFFF : ~u_fold[15:0];

    rdy_sr  <= rst ? '0 : {rdy_sr[CK_STAGES-2:0], decided && buy_r};
  end

  assign u_f    = 17'(u_sum[15:0]) + 17'(u_sum[31:16]);
  assign u_fold = 17'(u_f[15:0]) + 17'(u_f[16]);

  // ---------------------------------------------------------------- transmit

  typedef enum logic {T_IDLE, T_SEND} tstate_t;

  tstate_t    tstate;
  logic [6:0] idx;      // next reply byte to hand to rmii_tx
  logic       started;  // rmii_tx has started this frame

  wire fail = bad || early || (decided && !buy_r);

  wire data_ok = !fail
                 && (idx < RP_SEQ || have_seq)
                 && (idx < RP_PX  || buy_r)
                 && (idx < RP_CK  || ck_rdy)
                 && (idx < RP_UDP_CK || SPECULATIVE_TX || ck_rdy);

  wire start_now = SPECULATIVE_TX ? (rx_valid && rx_offset == 11'd0)
                                  : (at_last && buy_now);

  assign tx_valid = (tstate == T_SEND) && data_ok;
  assign tx_last  = (idx == 7'(RP_LEN - 1));

  always_comb begin
    tx_data = REPLY_FRAME[idx];
    if (idx == RP_UDP_CK)
      tx_data = SPECULATIVE_TX ? 8'h00 : udp_ck[15:8];
    else if (idx == RP_UDP_CK + 1)
      tx_data = SPECULATIVE_TX ? 8'h00 : udp_ck[7:0];
    else if (idx >= RP_SEQ && idx < RP_SEQ + 5)
      tx_data = seq[3'(idx - 7'(RP_SEQ))];
    else if (idx >= RP_CLORD && idx < RP_CLORD + 5)
      tx_data = seq[3'(idx - 7'(RP_CLORD))];
    else if (idx >= RP_PX && idx < RP_PX + 7)
      tx_data = px[3'(idx - 7'(RP_PX))];
    else if (idx >= RP_CK && idx < RP_CK + 3)
      tx_data = ck[2'(idx - 7'(RP_CK))];
  end

  logic sent_p, cut_p;

  always_ff @(posedge clk) begin
    sent_p <= 1'b0;
    cut_p  <= 1'b0;
    if (rst) begin
      tstate  <= T_IDLE;
      idx     <= '0;
      started <= 1'b0;
    end else begin
      case (tstate)
        T_IDLE:
          if (start_now) begin
            tstate  <= T_SEND;
            idx     <= '0;
            started <= 1'b0;
          end

        T_SEND:
          if (!started) begin
            if (tx_valid && !tx_busy)
              started <= 1'b1;   // rmii_tx takes the frame on this edge
            else if (!tx_valid)
              tstate <= T_IDLE;  // failed before anything went out
          end else if (tx_ready) begin
            if (tx_valid) begin
              idx <= idx + 7'd1;
              if (tx_last) begin
                tstate <= T_IDLE;
                sent_p <= 1'b1;
              end
            end else begin
              tstate <= T_IDLE;  // rmii_tx ends the frame with a wrong FCS
              cut_p  <= 1'b1;
            end
          end

        default: tstate <= T_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- counters

  always_ff @(posedge clk) begin
    buy      <= 1'b0;
    no_trade <= 1'b0;
    if (rst || clear) begin
      n_md      <= '0;
      n_buys    <= '0;
      n_ignored <= '0;
      n_sent    <= '0;
      n_cut     <= '0;
    end else begin
      if (at_last && md_ok_now) begin
        n_md     <= n_md + 32'd1;
        buy      <= buy_now;
        no_trade <= !buy_now;
        if (buy_now)
          n_buys <= n_buys + 32'd1;
      end
      if (rx_eof && !(decided && md_ok))
        n_ignored <= n_ignored + 32'd1;
      if (sent_p)
        n_sent <= n_sent + 32'd1;
      if (cut_p)
        n_cut <= n_cut + 32'd1;
    end
  end

endmodule
