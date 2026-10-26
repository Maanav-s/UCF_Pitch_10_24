`timescale 1ns / 1ps
// UART dump of the per-fair log:
//   # lat-arb n=<n>
//   <i>,<fv>,<fill_px>,<pnl_f>,<pnl_p>,<flags>
//   # done
// flags bit0 = F sniped, bit1 = P cancel too late. PnL is two's complement.

module event_dump
  import lat_arb_pkg::*;
#(
  parameter int CLK_HZ = 50_000_000,
  parameter int BAUD   = 115200
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        start,
  input  logic [4:0]  n,
  output logic [4:0]  rd_addr,
  input  logic [31:0] rd_fv,
  input  logic [31:0] rd_fill,
  input  logic [31:0] rd_pnl_f,
  input  logic [31:0] rd_pnl_p,
  input  logic [7:0]  rd_flags,
  output logic        tx,
  output logic        busy
);

  localparam logic [7:0] C_END  = 8'h00;
  localparam logic [7:0] C_LOOP = 8'h02;
  localparam logic [7:0] C_NEXT = 8'h03;

  localparam TPL_RAW = {
    "# lat-arb n=", 8'h80, "\n",
    C_LOOP, 8'h81, ",", 8'h82, ",", 8'h83, ",", 8'h84, ",", 8'h85, ",", 8'h86, "\n",
    C_NEXT,
    "# done\n",
    C_END
  };
  localparam int TPL_LEN = $bits(TPL_RAW) / 8;
  localparam logic [8*TPL_LEN-1:0] TPL = TPL_RAW;

  logic [7:0] p, c, loop_p, ch;

  always_comb begin
    c = C_END;
    for (int i = 0; i < TPL_LEN; i++)
      if (p == 8'(i))
        c = TPL[8 * (TPL_LEN - 1 - i) +: 8];
  end

  logic [31:0] val;
  always_comb begin
    unique case (c[3:0])
      4'd0:    val = {27'd0, n};
      4'd1:    val = {27'd0, rd_addr};
      4'd2:    val = rd_fv;
      4'd3:    val = rd_fill;
      4'd4:    val = rd_pnl_f;
      4'd5:    val = rd_pnl_p;
      4'd6:    val = {24'd0, rd_flags};
      default: val = '0;
    endcase
  end

  logic        tx_start, tx_busy, bcd_start, bcd_done;
  logic [7:0]  tx_data;
  logic [39:0] bcd;

  uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
    .clk, .rst, .start(tx_start), .data(tx_data), .tx, .busy(tx_busy)
  );
  bin2bcd u_bcd (
    .clk, .rst, .start(bcd_start), .bin(val), .bcd, .busy(), .done(bcd_done)
  );

  typedef enum logic [2:0] {D_IDLE, D_FETCH, D_CHAR, D_BCD, D_DIGIT, D_SKIP} state_t;
  (* fsm_encoding = "none" *) state_t state;
  logic [3:0] d;
  logic       started;
  wire        tx_free = !tx_busy && !tx_start;
  wire [3:0]  digit   = bcd[4 * d +: 4];

  assign busy = (state != D_IDLE) || tx_busy || tx_start;

  always_ff @(posedge clk) begin
    tx_start  <= 1'b0;
    bcd_start <= 1'b0;
    if (rst) begin
      state <= D_IDLE; p <= '0; rd_addr <= '0;
    end else unique case (state)
      D_IDLE:
        if (start) begin
          p <= '0; rd_addr <= '0; state <= D_FETCH;
        end
      D_FETCH:
        if (c == C_END)       state <= D_IDLE;
        else if (c == C_LOOP) begin
          rd_addr <= '0; loop_p <= p + 8'd1; p <= p + 8'd1;
          if (n == 0) state <= D_SKIP;
        end else if (c == C_NEXT) begin
          if (rd_addr + 5'd1 < n) begin
            rd_addr <= rd_addr + 5'd1; p <= loop_p;
          end else p <= p + 8'd1;
        end else if (c[7]) begin
          bcd_start <= 1'b1; state <= D_BCD;
        end else begin
          ch <= c; state <= D_CHAR;
        end
      D_CHAR:
        if (tx_free) begin
          tx_start <= 1'b1; tx_data <= ch; p <= p + 8'd1; state <= D_FETCH;
        end
      D_BCD:
        if (bcd_done) begin
          d <= 4'd9; started <= 1'b0; state <= D_DIGIT;
        end
      D_DIGIT:
        if (tx_free) begin
          if (digit != 4'd0 || started || d == 4'd0) begin
            tx_start <= 1'b1; tx_data <= 8'h30 + {4'd0, digit}; started <= 1'b1;
          end
          if (d == 4'd0) begin
            p <= p + 8'd1; state <= D_FETCH;
          end else d <= d - 4'd1;
        end
      D_SKIP: begin
        p <= p + 8'd1;
        if (c == C_NEXT) state <= D_FETCH;
      end
      default: state <= D_IDLE;
    endcase
  end

endmodule
