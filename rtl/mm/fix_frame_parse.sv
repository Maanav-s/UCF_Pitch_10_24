`timescale 1ns / 1ps
// FIX frame parser: checks a received frame against the mm_fix_pkg templates
// and extracts its fields as the bytes stream in.
//
// Input: one byte per in_valid, from the destination MAC onwards, FCS
// included, then one in_eof pulse (in a later cycle) at the end of the
// frame. That is what rmii_rx produces, and what rmii_port reproduces on the
// exchange side of its RX FIFO.
//
// TRADER_SIDE = 0: the frame must be a D or F (trader -> exchange);
// TRADER_SIDE = 1: an X, 8 or 9 (exchange -> trader). Bytes before the 35=
// value (frame offset TYPE_OFF) are checked against the group's first
// template; from there on against the template of the type seen. Map code
// F_NONE bytes must match, F_ANY bytes are not checked, digit fields must be
// ASCII digits. A frame is accepted (frame_ok, the cycle after in_eof) when
// nothing mismatched, its length is the type's length plus the 4 FCS bytes,
// and the CRC over the whole frame leaves the Ethernet residue. Everything
// else, including frames of other protocols, gives frame_bad.
//
// fields holds the message as parsed; it is valid with frame_ok and keeps
// its value until the next frame's bytes overwrite it. price_bin is the
// price in binary cents, built as the digits arrive.
//
// x_price_done (TRADER_SIDE only) pulses in the cycle after the last price
// digit of an X message has been taken in, if nothing has mismatched so
// far. fields.sym, fields.entry, fields.price and price_bin are valid then,
// before the frame has ended: the trader decides on it.

module fix_frame_parse
  import mm_fix_pkg::*;
  import mm_pkg::*;
  import crc32_pkg::*;
#(
  parameter bit TRADER_SIDE = 1'b0
) (
  input  logic        clk,
  input  logic        rst,

  input  logic        in_valid,
  input  logic [7:0]  in_data,
  input  logic        in_eof,

  output fix_fields_t fields,
  output logic [19:0] price_bin,
  output logic        frame_ok,
  output logic        frame_bad,
  output logic        x_price_done
);

  logic [7:0]  off;        // offset of the byte in in_data (saturates at 255)
  logic        type_known;
  logic [2:0]  mtype;
  logic        mismatch;
  logic [31:0] crc;

  // Template and map byte for the current offset.
  logic [7:0] tpl, map, type_len;

  always_comb begin
    tpl = 8'h00;
    map = 8'h00;
    if (off < 8'(TYPE_OFF) || !type_known) begin
      if (TRADER_SIDE) begin
        if (off < X_LEN) begin tpl = X_TPL[off]; map = X_MAP[off]; end
      end else begin
        if (off < D_LEN) begin tpl = D_TPL[off]; map = D_MAP[off]; end
      end
    end else begin
      case (mtype)
        MT_X:  if (off < X_LEN)  begin tpl = X_TPL[off];  map = X_MAP[off];  end
        MT_D:  if (off < D_LEN)  begin tpl = D_TPL[off];  map = D_MAP[off];  end
        MT_F:  if (off < F_LEN)  begin tpl = F_TPL[off];  map = F_MAP[off];  end
        MT_ER: if (off < ER_LEN) begin tpl = ER_TPL[off]; map = ER_MAP[off]; end
        default: if (off < CR_LEN) begin tpl = CR_TPL[off]; map = CR_MAP[off]; end
      endcase
    end
    case (mtype)
      MT_X:    type_len = 8'(X_LEN);
      MT_D:    type_len = 8'(D_LEN);
      MT_F:    type_len = 8'(F_LEN);
      MT_ER:   type_len = 8'(ER_LEN);
      default: type_len = 8'(CR_LEN);
    endcase
  end

  wire [3:0] code     = map[7:4];
  wire [3:0] k        = map[3:0];
  wire       is_digit = (in_data[7:4] == 4'h3) && (in_data[3:0] <= 4'd9);
  wire [3:0] d        = in_data[3:0];

  // The 35= value: which type, if any of this side's.
  logic       t_ok;
  logic [2:0] t_code;

  always_comb begin
    t_ok   = 1'b0;
    t_code = MT_X;
    if (TRADER_SIDE) begin
      case (in_data)
        T_X:  begin t_ok = 1'b1; t_code = MT_X;  end
        T_ER: begin t_ok = 1'b1; t_code = MT_ER; end
        T_CR: begin t_ok = 1'b1; t_code = MT_CR; end
        default: ;
      endcase
    end else begin
      case (in_data)
        T_D:  begin t_ok = 1'b1; t_code = MT_D; end
        T_F:  begin t_ok = 1'b1; t_code = MT_F; end
        default: ;
      endcase
    end
  end

  // A byte in a digit field that is not a digit, a fixed byte that differs,
  // or an unknown type.
  logic byte_bad;

  always_comb begin
    if (off == 8'(TYPE_OFF)) begin
      byte_bad = !t_ok;
    end else if (off > 8'(TYPE_OFF) && !type_known) begin
      byte_bad = 1'b1;
    end else if (type_known && off >= type_len) begin
      byte_bad = 1'b0;  // FCS bytes: covered by the CRC check at the end
    end else begin
      case (code)
        F_NONE:  byte_bad = (in_data != tpl);
        F_ANY:   byte_bad = 1'b0;
        F_SEQ, F_PRICE, F_SIZE, F_ORDID, F_CLORDID, F_ORIG, F_QTY, F_CKSUM:
                 byte_bad = !is_digit;
        default: byte_bad = 1'b0;  // characters: any value, checked by the user
      endcase
    end
  end

  wire eof_ok = type_known && !mismatch && (off == type_len + 8'd4)
                && (crc == CRC32_RESIDUE);

  always_ff @(posedge clk) begin
    frame_ok     <= 1'b0;
    frame_bad    <= 1'b0;
    x_price_done <= 1'b0;
    if (rst) begin
      off        <= '0;
      type_known <= 1'b0;
      mtype      <= MT_X;
      mismatch   <= 1'b0;
      crc        <= CRC32_INIT;
      fields     <= FIX_FIELDS_ZERO;
      price_bin  <= '0;
    end else if (in_eof) begin
      frame_ok   <= eof_ok;
      frame_bad  <= !eof_ok;
      off        <= '0;
      type_known <= 1'b0;
      mismatch   <= 1'b0;
      crc        <= CRC32_INIT;
    end else if (in_valid) begin
      crc <= crc32_byte(crc, in_data);
      if (off != 8'hFF)
        off <= off + 8'd1;
      if (byte_bad)
        mismatch <= 1'b1;
      if (off == 8'(TYPE_OFF) && t_ok) begin
        type_known   <= 1'b1;
        mtype        <= t_code;
        fields.mtype <= t_code;
      end
      // Field capture. BCD fields shift a digit in per byte; after all of a
      // field's digits the register holds them in order.
      case (code)
        F_SEQ:       fields.seq     <= {fields.seq[15:0], d};
        F_SYM:       fields.sym     <= {fields.sym[23:0], in_data};
        F_ENTRY:     fields.entry   <= in_data;
        F_PRICE: begin
          fields.price <= {fields.price[19:0], d};
          price_bin    <= (k == 4'd0) ? 20'(d) : price_bin * 20'd10 + 20'(d);
        end
        F_SIZE:      fields.size      <= {fields.size[15:0], d};
        F_ORDID:     fields.ordid     <= {fields.ordid[15:0], d};
        F_CLORDID:   fields.clordid   <= {fields.clordid[15:0], d};
        F_ORIG:      fields.orig      <= {fields.orig[15:0], d};
        F_EXECTYPE:  fields.exectype  <= in_data;
        F_ORDSTATUS: fields.ordstatus <= in_data;
        F_SIDE:      fields.side      <= in_data;
        F_REASON:    fields.reason    <= in_data;
        F_QTY:       fields.qty       <= {fields.qty[15:0], d};
        default: ;
      endcase
      if (TRADER_SIDE && type_known && mtype == MT_X && off == 8'(X_PRICE_LAST)
          && !mismatch && !byte_bad)
        x_price_done <= 1'b1;
    end
  end

endmodule
