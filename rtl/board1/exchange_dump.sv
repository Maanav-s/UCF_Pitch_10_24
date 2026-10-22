`timescale 1ns / 1ps
// UART dump of the sample log and statistics, as text. On start:
//
//   # run label=<A|B|C|D> tick_ns=20 samples=<n>
//   <i>,<ticks>                      one line per entry, i = 0 .. n-1
//   # min=<>,max=<>,replies=<>,timeouts=<>,other=<>,stale=<>
//
// Lines end in "\n"; numbers are unsigned decimal. A timeout entry prints as
// 4294967295 (0xFFFFFFFF). min/max/replies/timeouts/other/stale are
// exchange_core's statistics since the last clear or run start; min is
// 4294967295 when there was no reply. tools/capture.py reads this format.
//
// The text comes from the template TPL: plain characters are sent as they
// are, and the codes below insert the label, a number, or the per-entry loop.
// start is ignored while busy; busy stays high until the last stop bit.

module exchange_dump #(
  parameter int CLK_HZ  = 50_000_000,
  parameter int BAUD    = 115200,
  parameter int N       = 4096,  // sample_log size
  parameter int TICK_NS = 20
) (
  input  logic                 clk,
  input  logic                 rst,
  input  logic                 start,
  input  logic [1:0]           label,
  // sample_log read port (one clock of latency)
  output logic [$clog2(N)-1:0] rd_addr,
  input  logic [31:0]          rd_data,
  input  logic [31:0]          n_samples,
  // statistics
  input  logic [31:0]          lat_min,
  input  logic [31:0]          lat_max,
  input  logic [31:0]          n_replies,
  input  logic [31:0]          n_timeouts,
  input  logic [31:0]          n_other,
  input  logic [31:0]          n_stale,
  output logic                 tx,
  output logic                 busy
);

  // ---------------------------------------------------------------- template

  localparam logic [7:0] C_END   = 8'h00;  // end of the dump
  localparam logic [7:0] C_LABEL = 8'h01;  // 'A' + label
  localparam logic [7:0] C_LOOP  = 8'h02;  // start of the per-entry part
  localparam logic [7:0] C_NEXT  = 8'h03;  // end of it: next entry, or go on
  // 8'h80 + k: number k of the value mux below

  localparam TPL_RAW = {
    "# run label=", C_LABEL, " tick_ns=", 8'h80, " samples=", 8'h81, "\n",
    C_LOOP, 8'h82, ",", 8'h83, "\n", C_NEXT,
    "# min=", 8'h84, ",max=", 8'h85, ",replies=", 8'h86, ",timeouts=", 8'h87,
    ",other=", 8'h88, ",stale=", 8'h89, "\n",
    C_END
  };
  localparam int                 TPL_LEN = $bits(TPL_RAW) / 8;
  localparam logic [8*TPL_LEN-1:0] TPL     = TPL_RAW;

  logic [7:0] p;       // template position
  logic [7:0] loop_p;  // position after C_LOOP
  logic [7:0] c;

  // Template ROM, written with constant indices only. A variable part-select
  // of the wide TPL constant (TPL[8 * (TPL_LEN - 1 - p) +: 8]) crashed Vivado
  // 2025.2 synthesis (access violation after constraint processing). Positions
  // past the end read as C_END.
  always_comb begin
    c = C_END;
    for (int i = 0; i < TPL_LEN; i++)
      if (p == 8'(i))
        c = TPL[8 * (TPL_LEN - 1 - i) +: 8];
  end

  logic [31:0] val;

  always_comb begin
    case (c[3:0])
      4'd0:    val = 32'(TICK_NS);
      4'd1:    val = n_samples;
      4'd2:    val = 32'(rd_addr);
      4'd3:    val = rd_data;
      4'd4:    val = lat_min;
      4'd5:    val = lat_max;
      4'd6:    val = n_replies;
      4'd7:    val = n_timeouts;
      4'd8:    val = n_other;
      4'd9:    val = n_stale;
      default: val = '0;
    endcase
  end

  // ---------------------------------------------------------------- UART, BCD

  logic        tx_start, tx_busy;
  logic [7:0]  tx_data;
  logic        bcd_start, bcd_done;
  logic [39:0] bcd;

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
    .start (bcd_start),
    .bin   (val),
    .bcd   (bcd),
    .busy  (),
    .done  (bcd_done)
  );

  // ---------------------------------------------------------------- sequencer

  typedef enum logic [2:0] {D_IDLE, D_FETCH, D_CHAR, D_BCD, D_DIGIT, D_SKIP} state_t;

  // fsm_encoding "none": Vivado 2025.2 synthesis crashed (access violation)
  // during FSM extraction, apparently at this state machine. Keeping the
  // encoding as written avoids that step.
  (* fsm_encoding = "none" *) state_t state;
  logic [7:0] ch;
  logic [3:0] d;        // digit being sent, 9 down to 0
  logic       started;  // a non-zero digit has been sent (leading zeros skipped)

  wire       tx_free = !tx_busy && !tx_start;
  wire [3:0] digit   = bcd[4 * d +: 4];

  assign busy = (state != D_IDLE) || tx_busy || tx_start;

  always_ff @(posedge clk) begin
    tx_start  <= 1'b0;
    bcd_start <= 1'b0;
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
            if (n_samples == 0)
              state <= D_SKIP;
          end else if (c == C_NEXT) begin
            if (32'(rd_addr) + 32'd1 < n_samples) begin
              rd_addr <= rd_addr + 1'b1;
              p       <= loop_p;
            end else begin
              p <= p + 8'd1;
            end
          end else if (c[7]) begin
            bcd_start <= 1'b1;
            state     <= D_BCD;
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

        D_BCD:
          if (bcd_done) begin
            d       <= 4'd9;
            started <= 1'b0;
            state   <= D_DIGIT;
          end

        D_DIGIT:
          if (tx_free) begin
            if (digit != 4'd0 || started || d == 4'd0) begin
              tx_start <= 1'b1;
              tx_data  <= 8'h30 + {4'd0, digit};
              started  <= 1'b1;
            end
            if (d == 4'd0) begin
              p     <= p + 8'd1;
              state <= D_FETCH;
            end else begin
              d <= d - 4'd1;
            end
          end

        // No entries: skip to just after C_NEXT.
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
