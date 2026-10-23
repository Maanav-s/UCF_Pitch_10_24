`timescale 1ns / 1ps
// BISECT COPY a of trader_core (sim/bisect, generated). Sections: RMII, parser.
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

module tc_bis_a
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

  logic        in_frame;  // between a frame's first byte and its rx_eof
  logic        bad;       // a check failed (before the decision)
  logic        decided;   // the decision for this frame is made
  logic        md_ok;     // ... and the frame is valid market data
  logic        buy_r;     // ... and the rule says buy
  logic        early;     // the frame ended before byte 96
  logic        have_seq;  // MsgSeqNum captured
  logic        sym_ok, side_ok;
  logic [19:0] acc;       // price in cents, from the digits so far
  logic [7:0]  seq [5];   // MsgSeqNum digits
  logic [7:0]  px  [7];   // MDEntryPx characters, '.' included
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

  // Offsets that must equal MD_FRAME: everything except the source MAC
  // (6-11), IPv4 ID/flags/TTL (18-22), IPv4 checksum (24-25), UDP checksum
  // (40-41) and the decoded fields. Digits must be '0'-'9'.
  logic md_checked, is_digit, byte_bad;

  always_comb begin
    md_checked = 1'b1;
    if (rx_offset >= 6  && rx_offset <= 11) md_checked = 1'b0;
    if (rx_offset >= 18 && rx_offset <= 22) md_checked = 1'b0;
    if (rx_offset == 24 || rx_offset == 25) md_checked = 1'b0;
    if (rx_offset == 40 || rx_offset == 41) md_checked = 1'b0;
    if (off_seq || off_sym || off_pxd)      md_checked = 1'b0;
    if (rx_offset == MD_SIDE)               md_checked = 1'b0;

    is_digit = (rx_data >= "0") && (rx_data <= "9");
    byte_bad = (md_checked && rx_data != md_byte)
               || ((off_seq || off_pxd) && !is_digit);
  end

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
      for (int i = 0; i < 5; i++) seq[i] <= '0;
      for (int i = 0; i < 7; i++) px[i]  <= '0;
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
          case (rx_offset)
            MD_SEQ + 0: seq[0] <= rx_data;
            MD_SEQ + 1: seq[1] <= rx_data;
            MD_SEQ + 2: seq[2] <= rx_data;
            MD_SEQ + 3: seq[3] <= rx_data;
            MD_SEQ + 4: seq[4] <= rx_data;
            MD_PX  + 0: px[0]  <= rx_data;
            MD_PX  + 1: px[1]  <= rx_data;
            MD_PX  + 2: px[2]  <= rx_data;
            MD_PX  + 3: px[3]  <= rx_data;
            MD_PX  + 4: px[4]  <= rx_data;
            MD_PX  + 5: px[5]  <= rx_data;
            MD_PX  + 6: px[6]  <= rx_data;
            default: ;
          endcase
          if (rx_offset == MD_SEQ + 4)
            have_seq <= 1'b1;
          if (off_sym && rx_data != sym_byte)
            sym_ok <= 1'b0;
          if (rx_offset == MD_SIDE)
            side_ok <= (rx_data == "1");
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


  // ---------------------------------------------------------------- stub: transmit
  assign tx_valid = 1'b0;
  assign tx_data  = '0;
  assign tx_last  = 1'b0;

  // ---------------------------------------------------------------- stub: counters
  assign buy       = 1'b0;
  assign no_trade  = 1'b0;
  assign n_md      = '0;
  assign n_buys    = '0;
  assign n_ignored = '0;
  assign n_sent    = '0;
  assign n_cut     = '0;

endmodule
