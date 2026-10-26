`timescale 1ns / 1ps
// Two-slot book. Only P rests. F (and P) may send IOC.
// A resting bid/ask is accepted only if that slot is empty.
// Fill price is the resting price. BOOK_upd pulses when a rest improves
// an empty slot (the event F waits on after a snipe).

module book_match
  import lat_arb_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        clear,

  input  logic        cmd_valid,
  input  logic [7:0]  cmd_type,
  input  logic [7:0]  cmd_src,
  input  logic [31:0] cmd_oid,
  input  logic [7:0]  cmd_side,
  input  logic [7:0]  cmd_tif,
  input  logic [31:0] cmd_px,
  input  logic [15:0] cmd_sz,

  output logic        ack_valid,
  output logic [7:0]  ack_status,
  output logic [31:0] ack_oid,
  output logic [7:0]  ack_src,

  output logic        fill_valid,
  output logic [31:0] fill_oid_aggr,
  output logic [31:0] fill_oid_rest,
  output logic [7:0]  fill_src_aggr,
  output logic [7:0]  fill_src_rest,
  output logic [31:0] fill_px,
  output logic [15:0] fill_sz,
  output logic [7:0]  fill_side,     // aggressor's side

  output logic        book_upd,      // new rest landed in an empty slot
  output logic        bid_v,
  output logic [31:0] bid_oid, bid_px,
  output logic [15:0] bid_sz,
  output logic [7:0]  bid_owner,
  output logic        ask_v,
  output logic [31:0] ask_oid, ask_px,
  output logic [15:0] ask_sz,
  output logic [7:0]  ask_owner,

  output logic signed [15:0] pos_f, pos_p,
  output logic signed [31:0] cash_f, cash_p
);

  function automatic logic signed [31:0] signed_mul(
      input logic [31:0] px, input logic [15:0] sz);
    return $signed({1'b0, px}) * $signed({1'b0, sz});
  endfunction

  always_ff @(posedge clk) begin
    ack_valid  <= 1'b0;
    fill_valid <= 1'b0;
    book_upd   <= 1'b0;
    if (rst || clear) begin
      bid_v <= 1'b0; ask_v <= 1'b0;
      bid_oid <= '0; ask_oid <= '0;
      bid_px <= '0; ask_px <= '0;
      bid_sz <= '0; ask_sz <= '0;
      bid_owner <= '0; ask_owner <= '0;
    end else if (cmd_valid) begin
      ack_oid <= cmd_oid;
      ack_src <= cmd_src;
      ack_valid <= 1'b1;
      ack_status <= ACK_BAD_ORDER;

      if (cmd_type == T_CANCEL) begin
        if (bid_v && bid_oid == cmd_oid) begin
          bid_v <= 1'b0;
          ack_status <= ACK_CANCEL_OK;
        end else if (ask_v && ask_oid == cmd_oid) begin
          ask_v <= 1'b0;
          ack_status <= ACK_CANCEL_OK;
        end else begin
          ack_status <= ACK_CANCEL_TOO_LATE;
        end

      end else if (cmd_type == T_ORDER && cmd_sz != 0) begin
        if (cmd_side == SIDE_B && cmd_tif == TIF_IOC) begin
          if (ask_v && cmd_px >= ask_px) begin
            fill_valid     <= 1'b1;
            fill_oid_aggr  <= cmd_oid;
            fill_oid_rest  <= ask_oid;
            fill_src_aggr  <= cmd_src;
            fill_src_rest  <= ask_owner;
            fill_px        <= ask_px;
            fill_sz        <= (cmd_sz < ask_sz) ? cmd_sz : ask_sz;
            fill_side      <= SIDE_B;
            ack_status     <= ACK_FILLED;
            if (cmd_sz >= ask_sz) ask_v <= 1'b0;
            else ask_sz <= ask_sz - cmd_sz;
          end else begin
            ack_status <= ACK_NO_FILL;
          end

        end else if (cmd_side == SIDE_S && cmd_tif == TIF_IOC) begin
          if (bid_v && cmd_px <= bid_px) begin
            fill_valid     <= 1'b1;
            fill_oid_aggr  <= cmd_oid;
            fill_oid_rest  <= bid_oid;
            fill_src_aggr  <= cmd_src;
            fill_src_rest  <= bid_owner;
            fill_px        <= bid_px;
            fill_sz        <= (cmd_sz < bid_sz) ? cmd_sz : bid_sz;
            fill_side      <= SIDE_S;
            ack_status     <= ACK_FILLED;
            if (cmd_sz >= bid_sz) bid_v <= 1'b0;
            else bid_sz <= bid_sz - cmd_sz;
          end else begin
            ack_status <= ACK_NO_FILL;
          end

        end else if (cmd_side == SIDE_B && cmd_tif == TIF_REST) begin
          if (ask_v && cmd_px >= ask_px) begin
            fill_valid     <= 1'b1;
            fill_oid_aggr  <= cmd_oid;
            fill_oid_rest  <= ask_oid;
            fill_src_aggr  <= cmd_src;
            fill_src_rest  <= ask_owner;
            fill_px        <= ask_px;
            fill_sz        <= (cmd_sz < ask_sz) ? cmd_sz : ask_sz;
            fill_side      <= SIDE_B;
            ack_status     <= ACK_FILLED;
            if (cmd_sz >= ask_sz) ask_v <= 1'b0;
            else ask_sz <= ask_sz - cmd_sz;
          end else if (!bid_v) begin
            bid_v <= 1'b1;
            bid_oid <= cmd_oid; bid_px <= cmd_px; bid_sz <= cmd_sz;
            bid_owner <= cmd_src;
            ack_status <= ACK_ACCEPTED;
            book_upd <= 1'b1;
          end

        end else if (cmd_side == SIDE_S && cmd_tif == TIF_REST) begin
          if (bid_v && cmd_px <= bid_px) begin
            fill_valid     <= 1'b1;
            fill_oid_aggr  <= cmd_oid;
            fill_oid_rest  <= bid_oid;
            fill_src_aggr  <= cmd_src;
            fill_src_rest  <= bid_owner;
            fill_px        <= bid_px;
            fill_sz        <= (cmd_sz < bid_sz) ? cmd_sz : bid_sz;
            fill_side      <= SIDE_S;
            ack_status     <= ACK_FILLED;
            if (cmd_sz >= bid_sz) bid_v <= 1'b0;
            else bid_sz <= bid_sz - cmd_sz;
          end else if (!ask_v) begin
            ask_v <= 1'b1;
            ask_oid <= cmd_oid; ask_px <= cmd_px; ask_sz <= cmd_sz;
            ask_owner <= cmd_src;
            ack_status <= ACK_ACCEPTED;
            book_upd <= 1'b1;
          end
        end
      end
    end
  end

  // Ledger follows fill_valid (same cycle the pulse is registered).
  always_ff @(posedge clk) begin
    if (rst || clear) begin
      pos_f <= '0; pos_p <= '0; cash_f <= '0; cash_p <= '0;
    end else if (fill_valid) begin
      if (fill_side == SIDE_B) begin
        if (fill_src_aggr == SRC_F) begin
          pos_f  <= pos_f  + $signed(fill_sz);
          cash_f <= cash_f - signed_mul(fill_px, fill_sz);
        end else if (fill_src_aggr == SRC_P) begin
          pos_p  <= pos_p  + $signed(fill_sz);
          cash_p <= cash_p - signed_mul(fill_px, fill_sz);
        end
        if (fill_src_rest == SRC_F) begin
          pos_f  <= pos_f  - $signed(fill_sz);
          cash_f <= cash_f + signed_mul(fill_px, fill_sz);
        end else if (fill_src_rest == SRC_P) begin
          pos_p  <= pos_p  - $signed(fill_sz);
          cash_p <= cash_p + signed_mul(fill_px, fill_sz);
        end
      end else begin
        if (fill_src_aggr == SRC_F) begin
          pos_f  <= pos_f  - $signed(fill_sz);
          cash_f <= cash_f + signed_mul(fill_px, fill_sz);
        end else if (fill_src_aggr == SRC_P) begin
          pos_p  <= pos_p  - $signed(fill_sz);
          cash_p <= cash_p + signed_mul(fill_px, fill_sz);
        end
        if (fill_src_rest == SRC_F) begin
          pos_f  <= pos_f  + $signed(fill_sz);
          cash_f <= cash_f - signed_mul(fill_px, fill_sz);
        end else if (fill_src_rest == SRC_P) begin
          pos_p  <= pos_p  + $signed(fill_sz);
          cash_p <= cash_p - signed_mul(fill_px, fill_sz);
        end
      end
    end
  end

endmodule
