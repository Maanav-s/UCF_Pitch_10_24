`timescale 1ns / 1ps
// FIX frame generator: streams one of the mm_fix_pkg templates with the
// message's fields patched in, as a byte stream from the destination MAC to
// the end of the UDP payload. The caller (rmii_tx, or a TX FIFO) appends the
// FCS. The FIX CheckSum (10=) is computed on the fly.
//
// start (ignored while busy) samples f_in and begins the frame. One byte is
// handed over per clock where out_valid && out_ready; out_last marks the
// last byte. busy stays high until the last byte has been taken.
//
// Each template byte's map entry says what goes out: the template byte
// itself (F_NONE / F_ANY), a digit or character of a field, or a CheckSum
// digit. The digit index counts from the most significant digit, so digit k
// of an n-digit BCD field is nibble n-1-k.

module fix_frame_gen
  import mm_fix_pkg::*;
  import mm_pkg::*;
(
  input  logic        clk,
  input  logic        rst,

  input  logic        start,
  input  fix_fields_t f_in,

  output logic        out_valid,
  output logic [7:0]  out_data,
  output logic        out_last,
  input  logic        out_ready,
  output logic        busy
);

  fix_fields_t f;
  logic [7:0]  idx;   // byte being offered
  logic [7:0]  sum;   // FIX CheckSum accumulator
  logic [7:0]  len;   // frame length of f.mtype

  always_comb begin
    case (f.mtype)
      MT_X:    len = 8'(X_LEN);
      MT_D:    len = 8'(D_LEN);
      MT_F:    len = 8'(F_LEN);
      MT_ER:   len = 8'(ER_LEN);
      default: len = 8'(CR_LEN);
    endcase
  end

  // Template and map byte at idx. Out-of-range indices read as 0 so the
  // simulator never sees an X.
  logic [7:0] tpl, map;

  always_comb begin
    tpl = 8'h00;
    map = 8'h00;
    case (f.mtype)
      MT_X:  if (idx < X_LEN)  begin tpl = X_TPL[idx];  map = X_MAP[idx];  end
      MT_D:  if (idx < D_LEN)  begin tpl = D_TPL[idx];  map = D_MAP[idx];  end
      MT_F:  if (idx < F_LEN)  begin tpl = F_TPL[idx];  map = F_MAP[idx];  end
      MT_ER: if (idx < ER_LEN) begin tpl = ER_TPL[idx]; map = ER_MAP[idx]; end
      default: if (idx < CR_LEN) begin tpl = CR_TPL[idx]; map = CR_MAP[idx]; end
    endcase
  end

  // ASCII digit k (from the most significant) of an n-digit BCD value.
  function automatic logic [7:0] digit_of(input logic [23:0] v, input int n, input logic [3:0] k);
    logic [3:0] d;
    d = 4'd0;
    for (int i = 0; i < 6; i++)
      if (i == n - 1 - int'(k))
        d = v[4*i +: 4];
    return 8'h30 + {4'd0, d};
  endfunction

  // Digit k of the 3-digit decimal CheckSum.
  function automatic logic [7:0] cks_digit(input logic [7:0] s, input logic [3:0] k);
    logic [7:0] h, t, u;
    h = s / 8'd100;
    t = (s / 8'd10) % 8'd10;
    u = s % 8'd10;
    case (k)
      4'd0:    return 8'h30 + h;
      4'd1:    return 8'h30 + t;
      default: return 8'h30 + u;
    endcase
  endfunction

  wire [3:0] code = map[7:4];
  wire [3:0] k    = map[3:0];

  always_comb begin
    case (code)
      F_SEQ:       out_data = digit_of({4'd0, f.seq}, 5, k);
      F_SYM:       out_data = f.sym[8*(3 - k) +: 8];
      F_ENTRY:     out_data = f.entry;
      F_PRICE:     out_data = digit_of(f.price, 6, k);
      F_SIZE:      out_data = digit_of({4'd0, f.size}, 5, k);
      F_ORDID:     out_data = digit_of({4'd0, f.ordid}, 5, k);
      F_CLORDID:   out_data = digit_of({4'd0, f.clordid}, 5, k);
      F_ORIG:      out_data = digit_of({4'd0, f.orig}, 5, k);
      F_EXECTYPE:  out_data = f.exectype;
      F_ORDSTATUS: out_data = f.ordstatus;
      F_SIDE:      out_data = f.side;
      F_REASON:    out_data = f.reason;
      F_QTY:       out_data = digit_of({4'd0, f.qty}, 5, k);
      F_CKSUM:     out_data = cks_digit(sum, k);
      default:     out_data = tpl;
    endcase
  end

  assign out_valid = busy;
  assign out_last  = (idx == len - 8'd1);

  wire take = out_valid && out_ready;

  // CheckSum covers the payload bytes before "10=": frame offsets ETH_HDR
  // to len-8 inclusive (the trailer "10=ccc|" is the last 7 bytes).
  wire in_sum = (idx >= 8'(ETH_HDR)) && (idx < len - 8'd7);

  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0;
      idx  <= '0;
      sum  <= '0;
      f    <= FIX_FIELDS_ZERO;
    end else if (!busy) begin
      if (start) begin
        f    <= f_in;
        idx  <= '0;
        sum  <= '0;
        busy <= 1'b1;
      end
    end else if (take) begin
      idx <= idx + 8'd1;
      if (in_sum)
        sum <= sum + out_data;
      if (out_last)
        busy <= 1'b0;
    end
  end

endmodule
