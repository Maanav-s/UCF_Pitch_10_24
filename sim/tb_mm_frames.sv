`timescale 1ns / 1ps
// Testbench for fix_frame_gen and fix_frame_parse against the Python frames
// (tools/mm_vectors.py: sim/mm/gen_*.mem).
//
// For each of the N vectors:
//   1. fix_frame_gen is started with the record's fields; its byte stream
//      must equal the frame without its FCS, byte for byte (CheckSum too).
//   2. The whole frame (FCS included) is fed into the parser of the side
//      that receives this type, one byte every 4 clocks, then in_eof. It
//      must report frame_ok, and every field the type carries must match
//      the record; price_bin must equal the price.
//   3. The frame with one byte corrupted must give frame_bad.
// Also: the trader-side parser must pulse x_price_done after frame offset
// X_PRICE_LAST of an X frame, with the price already valid.
//
// Prints "TB_MM_FRAMES PASS" or "TB_MM_FRAMES FAIL (<n> errors)".

module tb_mm_frames
  import mm_fix_pkg::*;
  import mm_pkg::*;
#(
  parameter string VEC_DIR = "../../../../sim/mm"
) ();
  localparam int N      = 24;
  localparam int STRIDE = 160;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #10 clk = ~clk;

  int errors = 0;

  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      $display("ERROR %0t: %s", $time, msg);
      errors++;
    end
  endtask

  // ---------------------------------------------------------------- vectors

  logic [31:0] rec    [0:14*N-1];
  logic [7:0]  frames [0:STRIDE*N-1];
  logic [7:0]  lens   [0:N-1];

  initial begin
    $readmemh({VEC_DIR, "/gen_fields.mem"}, rec);
    $readmemh({VEC_DIR, "/gen_frames.mem"}, frames);
    $readmemh({VEC_DIR, "/gen_len.mem"}, lens);
  end

  function automatic fix_fields_t rec_fields(input int i);
    fix_fields_t f;
    f           = FIX_FIELDS_ZERO;
    f.mtype     = rec[14*i + 0][2:0];
    f.seq       = rec[14*i + 1][19:0];
    f.clordid   = rec[14*i + 2][19:0];
    f.ordid     = rec[14*i + 3][19:0];
    f.orig      = rec[14*i + 4][19:0];
    f.qty       = rec[14*i + 5][19:0];
    f.size      = rec[14*i + 6][19:0];
    f.price     = rec[14*i + 7][23:0];
    f.sym       = rec[14*i + 8];
    f.entry     = rec[14*i + 9][7:0];
    f.exectype  = rec[14*i + 10][7:0];
    f.ordstatus = rec[14*i + 11][7:0];
    f.side      = rec[14*i + 12][7:0];
    f.reason    = rec[14*i + 13][7:0];
    return f;
  endfunction

  // ---------------------------------------------------------------- DUTs

  logic        g_start = 1'b0, g_valid, g_last, g_ready = 1'b0, g_busy;
  logic [7:0]  g_data;
  fix_fields_t g_in;

  fix_frame_gen u_gen (
    .clk       (clk),
    .rst       (rst),
    .start     (g_start),
    .f_in      (g_in),
    .out_valid (g_valid),
    .out_data  (g_data),
    .out_last  (g_last),
    .out_ready (g_ready),
    .busy      (g_busy)
  );

  logic        p_valid = 1'b0, p_eof = 1'b0;
  logic [7:0]  p_data  = '0;
  fix_fields_t pt_fields, pe_fields;
  logic [19:0] pt_price_bin, pe_price_bin;
  logic        pt_ok, pt_bad, pt_xdone, pe_ok, pe_bad;

  fix_frame_parse #(.TRADER_SIDE(1'b1)) u_parse_tr (
    .clk          (clk),
    .rst          (rst),
    .in_valid     (p_valid),
    .in_data      (p_data),
    .in_eof       (p_eof),
    .fields       (pt_fields),
    .price_bin    (pt_price_bin),
    .frame_ok     (pt_ok),
    .frame_bad    (pt_bad),
    .x_price_done (pt_xdone)
  );

  fix_frame_parse #(.TRADER_SIDE(1'b0)) u_parse_ex (
    .clk          (clk),
    .rst          (rst),
    .in_valid     (p_valid),
    .in_data      (p_data),
    .in_eof       (p_eof),
    .fields       (pe_fields),
    .price_bin    (pe_price_bin),
    .frame_ok     (pe_ok),
    .frame_bad    (pe_bad),
    .x_price_done ()
  );

  // Count result pulses and remember x_price_done.
  int n_ok_t = 0, n_bad_t = 0, n_ok_e = 0, n_bad_e = 0, n_xdone = 0;
  logic [23:0] xdone_price;
  int xdone_at = -1;   // byte offset being streamed when x_price_done came
  int stream_off = -1;

  always @(posedge clk) begin
    if (pt_ok)  n_ok_t++;
    if (pt_bad) n_bad_t++;
    if (pe_ok)  n_ok_e++;
    if (pe_bad) n_bad_e++;
    if (pt_xdone) begin
      n_xdone++;
      xdone_price = pt_fields.price;
      xdone_at    = stream_off;
    end
  end

  // ---------------------------------------------------------------- tasks

  logic [7:0] fr [0:STRIDE-1];
  int         flen;

  task automatic load(input int i);
    for (int k = 0; k < STRIDE; k++) fr[k] = frames[STRIDE*i + k];
    flen = lens[i];
  endtask

  // Monitor the handshake on the rising edge and compare each byte taken.
  int   g_k = 0;
  logic g_check_on = 1'b0;
  int   g_vec = 0;

  always @(posedge clk) begin
    if (g_check_on && g_valid && g_ready) begin
      if (g_data !== frames[STRIDE*g_vec + g_k]) begin
        $display("ERROR %0t: vector %0d gen byte %0d = %02x, expected %02x",
                 $time, g_vec, g_k, g_data, frames[STRIDE*g_vec + g_k]);
        errors++;
      end
      if (g_last !== (g_k == lens[g_vec] - 5)) begin
        $display("ERROR %0t: vector %0d out_last at byte %0d", $time, g_vec, g_k);
        errors++;
      end
      g_k++;
    end
  end

  task automatic run_gen(input int i);
    @(negedge clk);
    g_vec      = i;
    g_k        = 0;
    g_check_on = 1'b1;
    g_in       = rec_fields(i);
    g_start    = 1'b1;
    @(negedge clk);
    g_start = 1'b0;
    while (g_busy) begin
      g_ready = ($urandom_range(0, 3) != 0);
      @(negedge clk);
    end
    g_ready    = 1'b0;
    g_check_on = 1'b0;
    check(g_k == flen - 4, $sformatf("vector %0d: generated %0d bytes, expected %0d", i, g_k, flen - 4));
  endtask

  // Stream fr[0 .. flen-1] into both parsers, one byte per 4 clocks.
  task automatic stream(input bit corrupt);
    logic [7:0] b;
    for (int k = 0; k < flen; k++) begin
      b = fr[k];
      if (corrupt && k == 70) b = b ^ 8'h01;
      @(negedge clk);
      stream_off = k;
      p_valid = 1'b1;
      p_data  = b;
      @(negedge clk);
      p_valid = 1'b0;
      repeat (2) @(negedge clk);
    end
    @(negedge clk);
    p_eof = 1'b1;
    @(negedge clk);
    p_eof = 1'b0;
    repeat (3) @(negedge clk);
  endtask

  function automatic logic [19:0] bcd2bin(input logic [23:0] b);
    logic [19:0] r;
    r = 0;
    for (int i = 5; i >= 0; i--)
      r = r * 20'd10 + 20'(b[4*i +: 4]);
    return r;
  endfunction

  task automatic parse_check(input int i);
    fix_fields_t e, g;
    bit tr;
    int ok_t0, ok_e0, bad_t0, bad_e0;
    e  = rec_fields(i);
    tr = (e.mtype == MT_X || e.mtype == MT_ER || e.mtype == MT_CR);
    ok_t0 = n_ok_t; ok_e0 = n_ok_e; bad_t0 = n_bad_t; bad_e0 = n_bad_e;
    n_xdone = 0;
    stream(1'b0);
    if (tr) begin
      check(n_ok_t == ok_t0 + 1 && n_bad_t == bad_t0, $sformatf("vector %0d: trader parser did not accept", i));
      check(n_bad_e == bad_e0 + 1, $sformatf("vector %0d: exchange parser accepted a trader-side type", i));
      g = pt_fields;
      check(pt_price_bin == bcd2bin(e.price) || e.mtype == MT_CR,
            $sformatf("vector %0d: price_bin %0d", i, pt_price_bin));
    end else begin
      check(n_ok_e == ok_e0 + 1 && n_bad_e == bad_e0, $sformatf("vector %0d: exchange parser did not accept", i));
      check(n_bad_t == bad_t0 + 1, $sformatf("vector %0d: trader parser accepted an exchange-side type", i));
      g = pe_fields;
      check(pe_price_bin == bcd2bin(e.price) || e.mtype == MT_F,
            $sformatf("vector %0d: price_bin %0d", i, pe_price_bin));
    end
    check(g.mtype == e.mtype, $sformatf("vector %0d: mtype %0d", i, g.mtype));
    check(g.seq == e.seq, $sformatf("vector %0d: seq %05x", i, g.seq));
    case (e.mtype)
      MT_X: begin
        check(g.sym == e.sym && g.entry == e.entry && g.price == e.price && g.size == e.size,
              $sformatf("vector %0d: X fields", i));
        check(n_xdone == 1 && xdone_price == e.price && xdone_at == X_PRICE_LAST,
              $sformatf("vector %0d: x_price_done (count %0d, at %0d)", i, n_xdone, xdone_at));
      end
      MT_D:  check(g.clordid == e.clordid && g.sym == e.sym && g.side == e.side && g.qty == e.qty
                   && g.price == e.price, $sformatf("vector %0d: D fields", i));
      MT_F:  check(g.clordid == e.clordid && g.orig == e.orig && g.sym == e.sym && g.side == e.side,
                   $sformatf("vector %0d: F fields", i));
      MT_ER: check(g.ordid == e.ordid && g.clordid == e.clordid && g.exectype == e.exectype
                   && g.ordstatus == e.ordstatus && g.sym == e.sym && g.side == e.side
                   && g.price == e.price && g.qty == e.qty, $sformatf("vector %0d: ER fields", i));
      default: check(g.ordid == e.ordid && g.clordid == e.clordid && g.orig == e.orig
                     && g.ordstatus == e.ordstatus && g.reason == e.reason,
                     $sformatf("vector %0d: CR fields", i));
    endcase
    // Corrupted: nobody accepts it.
    ok_t0 = n_ok_t; ok_e0 = n_ok_e;
    stream(1'b1);
    check(n_ok_t == ok_t0 && n_ok_e == ok_e0, $sformatf("vector %0d: corrupted frame accepted", i));
  endtask

  // ---------------------------------------------------------------- run

  initial begin
    repeat (5) @(posedge clk);
    rst = 1'b0;
    repeat (5) @(posedge clk);
    for (int i = 0; i < N; i++) begin
      load(i);
      run_gen(i);
      parse_check(i);
    end
    if (errors == 0)
      $display("TB_MM_FRAMES PASS");
    else
      $display("TB_MM_FRAMES FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #(20ms);
    $display("TB_MM_FRAMES FAIL (watchdog)");
    $finish;
  end

endmodule
