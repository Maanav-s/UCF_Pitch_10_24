`timescale 1ns / 1ps
// UART dump of the event log as text (docs/mm_protocol.md):
//
//   # mm label=<A|B|C|D> tick_ns=20 events=<n>
//   <i>,<ticks>,<rx|tx>,<L|F|B>,<X|D|F|8|9>,<side>,<status>,<clordid>,<orderid>,<price>
//   ...
//   # steps=<n>,fills=<n>,rx_bad=<n>
//
// i and ticks are decimal; side and status are the FIX characters, or "-"
// when the message has none; clordid and orderid are 5 digits, price 6
// digits (cents), as in the messages. tools/capture.py records this and
// tools/race.py reads it.
//
// Built like exchange_dump: a template of plain characters and codes that
// insert a number (via bin2bcd), a character, a BCD field or the per-entry
// loop. start is ignored while busy.

module mm_dump
  import mm_pkg::*;
#(
  parameter int CLK_HZ  = 50_000_000,
  parameter int BAUD    = 115200,
  parameter int N       = 1024,
  parameter int TICK_NS = 20
) (
  input  logic                 clk,
  input  logic                 rst,
  input  logic                 start,
  input  logic [1:0]           label,
  output logic [$clog2(N)-1:0] rd_addr,
  input  log_entry_t           rd_data,     // entry at rd_addr, one clock later
  input  logic [31:0]          n_events,
  input  logic [31:0]          n_steps,
  input  logic [31:0]          n_fills,
  input  logic [31:0]          n_bad,
  output logic                 tx,
  output logic                 busy
);

  // ---------------------------------------------------------------- template

  localparam logic [7:0] C_END   = 8'h00;
  localparam logic [7:0] C_LABEL = 8'h01;
  localparam logic [7:0] C_LOOP  = 8'h02;
  localparam logic [7:0] C_NEXT  = 8'h03;
  // 8'h04 + k: BCD field k;  8'h10 + k: character k;  8'h80 + k: number k.
  // All codes are control characters, so they cannot collide with the text.

  localparam TPL_RAW = {
    "# mm label=", C_LABEL, " tick_ns=", 8'h80, " events=", 8'h81, "\n",
    C_LOOP, 8'h82, ",", 8'h83, ",", 8'h10, "x,", 8'h11, ",", 8'h12, ",", 8'h13, ",",
    8'h14, ",", 8'h04, ",", 8'h05, ",", 8'h06, "\n", C_NEXT,
    "# steps=", 8'h84, ",fills=", 8'h85, ",rx_bad=", 8'h86, "\n",
    C_END
  };
  localparam int                   TPL_LEN = $bits(TPL_RAW) / 8;
  localparam logic [8*TPL_LEN-1:0] TPL     = TPL_RAW;

  logic [7:0] p, loop_p, c;

  // Constant-index mux over the template (a variable part-select of the wide
  // constant crashed Vivado 2025.2 synthesis in exchange_dump).
  always_comb begin
    c = C_END;
    for (int i = 0; i < TPL_LEN; i++)
      if (p == 8'(i))
        c = TPL[8 * (TPL_LEN - 1 - i) +: 8];
  end

  // ---------------------------------------------------------------- values

  logic [31:0] num;

  always_comb begin
    case (c[3:0])
      4'd0:    num = 32'(TICK_NS);
      4'd1:    num = n_events;
      4'd2:    num = 32'(rd_addr);
      4'd3:    num = rd_data.ts;
      4'd4:    num = n_steps;
      4'd5:    num = n_fills;
      default: num = n_bad;
    endcase
  end

  function automatic logic [7:0] type_char(input logic [2:0] t);
    case (t)
      MT_X:    return 8'h58;  // X
      MT_D:    return 8'h44;  // D
      MT_F:    return 8'h46;  // F
      MT_ER:   return 8'h38;  // 8
      default: return 8'h39;  // 9
    endcase
  endfunction

  logic [7:0] chr;

  always_comb begin
    case (c[3:0])
      4'd0:    chr = rd_data.dir_tx ? 8'h74 : 8'h72;                       // t / r
      4'd1:    chr = (rd_data.port == PORT_L) ? 8'h4C :
                     (rd_data.port == PORT_F) ? 8'h46 : 8'h42;              // L / F / B
      4'd2:    chr = type_char(rd_data.mtype);
      4'd3:    chr = (rd_data.side   == 8'h00) ? 8'h2D : rd_data.side;     // - if none
      default: chr = (rd_data.status == 8'h00) ? 8'h2D : rd_data.status;
    endcase
  end

  logic [23:0] bcd_fld;
  logic [3:0]  bcd_ndig;

  always_comb begin
    case (c)
      8'h04:   begin bcd_fld = {4'd0, rd_data.clordid}; bcd_ndig = 4'd5; end
      8'h05:   begin bcd_fld = {4'd0, rd_data.ordid};   bcd_ndig = 4'd5; end
      default: begin bcd_fld = rd_data.price;           bcd_ndig = 4'd6; end
    endcase
  end

  // ---------------------------------------------------------------- UART, BCD

  logic        tx_start, tx_busy;
  logic [7:0]  tx_data;
  logic        b2b_start, b2b_done;
  logic [39:0] b2b;

  uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
    .clk   (clk),
    .rst   (rst),
    .start (tx_start),
    .data  (tx_data),
    .tx    (tx),
    .busy  (tx_busy)
  );

  bin2bcd u_bcd (
    .clk   (clk),
    .rst   (rst),
    .start (b2b_start),
    .bin   (num),
    .bcd   (b2b),
    .busy  (),
    .done  (b2b_done)
  );

  // ---------------------------------------------------------------- sequencer

  typedef enum logic [2:0] {D_IDLE, D_FETCH, D_CHAR, D_NUM, D_NUMDIG, D_FLDDIG, D_SKIP} state_t;

  (* fsm_encoding = "none" *) state_t state;
  logic [7:0] ch;
  logic [3:0] d;        // digit being sent, counting down to 0
  logic       started;  // a non-zero digit has been sent (leading zeros skipped)

  wire       tx_free    = !tx_busy && !tx_start;
  wire [3:0] num_digit  = b2b[4 * d +: 4];
  logic [3:0] fld_digit;

  always_comb begin
    fld_digit = 4'd0;
    for (int i = 0; i < 6; i++)
      if (d == 4'(i))
        fld_digit = bcd_fld[4 * i +: 4];
  end

  assign busy = (state != D_IDLE) || tx_busy || tx_start;

  always_ff @(posedge clk) begin
    tx_start  <= 1'b0;
    b2b_start <= 1'b0;
    if (rst) begin
      state   <= D_IDLE;
      p       <= '0;
      loop_p  <= '0;
      rd_addr <= '0;
      ch      <= '0;
      d       <= '0;
      started <= 1'b0;
      tx_data <= '0;
    end else begin
      case (state)
        D_IDLE:
          if (start) begin
            p       <= '0;
            rd_addr <= '0;
            state   <= D_FETCH;
          end

        D_FETCH:
          if (c == C_END) begin
            state <= D_IDLE;
          end else if (c == C_LOOP) begin
            rd_addr <= '0;
            loop_p  <= p + 8'd1;
            p       <= p + 8'd1;
            if (n_events == 0)
              state <= D_SKIP;
          end else if (c == C_NEXT) begin
            if (32'(rd_addr) + 32'd1 < n_events) begin
              rd_addr <= rd_addr + 1'b1;
              p       <= loop_p;
            end else begin
              p <= p + 8'd1;
            end
          end else if (c[7]) begin
            b2b_start <= 1'b1;
            state     <= D_NUM;
          end else if (c >= 8'h04 && c <= 8'h06) begin
            d       <= bcd_ndig - 4'd1;
            state   <= D_FLDDIG;
          end else if (c[7:4] == 4'h1) begin
            ch    <= chr;
            state <= D_CHAR;
          end else begin
            ch    <= (c == C_LABEL) ? 8'h41 + {6'd0, label} : c;
            state <= D_CHAR;
          end

        D_CHAR:
          if (tx_free) begin
            tx_start <= 1'b1;
            tx_data  <= ch;
            p        <= p + 8'd1;
            state    <= D_FETCH;
          end

        D_NUM:
          if (b2b_done) begin
            d       <= 4'd9;
            started <= 1'b0;
            state   <= D_NUMDIG;
          end

        D_NUMDIG:
          if (tx_free) begin
            if (num_digit != 4'd0 || started || d == 4'd0) begin
              tx_start <= 1'b1;
              tx_data  <= 8'h30 + {4'd0, num_digit};
              started  <= 1'b1;
            end
            if (d == 4'd0) begin
              p     <= p + 8'd1;
              state <= D_FETCH;
            end else begin
              d <= d - 4'd1;
            end
          end

        // Fixed-width BCD field: every digit, most significant first.
        D_FLDDIG:
          if (tx_free) begin
            tx_start <= 1'b1;
            tx_data  <= 8'h30 + {4'd0, fld_digit};
            if (d == 4'd0) begin
              p     <= p + 8'd1;
              state <= D_FETCH;
            end else begin
              d <= d - 4'd1;
            end
          end

        D_SKIP: begin
          p <= p + 8'd1;
          if (c == C_NEXT)
            state <= D_FETCH;
        end

        default: state <= D_IDLE;
      endcase
    end
  end

endmodule
