`timescale 1ns / 1ps
// Shared types for the two-trader exchange (docs/mm_protocol.md).

package mm_pkg;

  // Message type codes used inside the design (the FIX 35= characters are in
  // mm_fix_pkg: T_X, T_D, T_F, T_ER, T_CR).
  localparam logic [2:0] MT_X  = 3'd0;  // Market Data Incremental Refresh
  localparam logic [2:0] MT_D  = 3'd1;  // New Order Single
  localparam logic [2:0] MT_F  = 3'd2;  // Order Cancel Request
  localparam logic [2:0] MT_ER = 3'd3;  // Execution Report
  localparam logic [2:0] MT_CR = 3'd4;  // Order Cancel Reject

  // ASCII values of the one-character fields.
  localparam logic [7:0] CH_BUY      = 8'h31;  // 54=1
  localparam logic [7:0] CH_SELL     = 8'h32;  // 54=2
  localparam logic [7:0] CH_BID      = 8'h30;  // 269=0
  localparam logic [7:0] CH_OFFER    = 8'h31;  // 269=1
  localparam logic [7:0] CH_TRADE    = 8'h32;  // 269=2
  localparam logic [7:0] CH_NEW      = 8'h30;  // 150=0 / 39=0
  localparam logic [7:0] CH_FILLED   = 8'h32;  // 39=2
  localparam logic [7:0] CH_TRADEX   = 8'h46;  // 150=F
  localparam logic [7:0] CH_CANCELED = 8'h34;  // 150=4 / 39=4
  localparam logic [7:0] CH_REJECTED = 8'h38;  // 150=8 / 39=8
  localparam logic [7:0] CH_TOOLATE  = 8'h30;  // 102=0
  localparam logic [7:0] CH_UNKNOWN  = 8'h31;  // 102=1

  // The fields of one message, as fix_frame_gen takes them and
  // fix_frame_parse delivers them. Numbers are packed BCD, most significant
  // digit in the top nibble; characters are ASCII. A type uses only some of
  // them (see mm_fix_pkg's maps); the rest are ignored.
  typedef struct packed {
    logic [2:0]  mtype;
    logic [19:0] seq;        // 34
    logic [19:0] clordid;    // 11
    logic [19:0] ordid;      // 37
    logic [19:0] orig;       // 41
    logic [19:0] qty;        // 38
    logic [19:0] size;       // 271
    logic [23:0] price;      // 270 / 44, cents
    logic [31:0] sym;        // 55
    logic [7:0]  entry;      // 269
    logic [7:0]  exectype;   // 150
    logic [7:0]  ordstatus;  // 39
    logic [7:0]  side;       // 54
    logic [7:0]  reason;     // 102
  } fix_fields_t;

  localparam fix_fields_t FIX_FIELDS_ZERO = '0;

  // Destination ports of an exchange message.
  localparam logic [1:0] PORT_L    = 2'd0;  // laptop, exchange PHY on JB
  localparam logic [1:0] PORT_F    = 2'd1;  // FPGA trader, exchange PHY on JC
  localparam logic [1:0] PORT_BOTH = 2'd2;

  // Event log entry (mm_event_log, mm_dump).
  typedef struct packed {
    logic [9:0]  spare;
    logic [23:0] price;      // BCD cents
    logic [19:0] ordid;      // 37, or 41 for a cancel request
    logic [19:0] clordid;    // 11
    logic [7:0]  status;     // 150 of a report, 102 of a cancel reject, else 0
    logic [7:0]  side;       // 54, or 269 of market data, else 0
    logic [2:0]  mtype;
    logic [1:0]  port;       // PORT_*
    logic        dir_tx;     // 1 = sent by the exchange, 0 = received
    logic [31:0] ts;         // clk_ex ticks
  } log_entry_t;

  // Add one to a packed BCD number, wrapping at 10^digits.
  function automatic logic [19:0] bcd_inc5(input logic [19:0] v);
    logic [19:0] r;
    logic carry;
    r = v;
    carry = 1'b1;
    for (int i = 0; i < 5; i++) begin
      if (carry) begin
        if (r[4*i +: 4] == 4'd9) begin
          r[4*i +: 4] = 4'd0;
        end else begin
          r[4*i +: 4] = r[4*i +: 4] + 4'd1;
          carry = 1'b0;
        end
      end
    end
    return r;
  endfunction

endpackage
