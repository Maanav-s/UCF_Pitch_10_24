`timescale 1ns / 1ps
// Button debouncer. The asynchronous input is synchronized with
// xpm_cdc_single, then must hold a new level for CLKS clocks before the
// output follows. rise pulses for one clock when the output goes high.

module debounce #(
  parameter int CLKS = 500_000  // 10 ms at 50 MHz
) (
  input  logic clk,
  input  logic rst,
  input  logic btn_async,
  output logic level,
  output logic rise
);

  logic btn;
  logic [$clog2(CLKS + 1)-1:0] cnt;

  xpm_cdc_single #(
    .DEST_SYNC_FF   (2),
    .INIT_SYNC_FF   (1),
    .SIM_ASSERT_CHK (0),
    .SRC_INPUT_REG  (0)
  ) u_sync (
    .src_clk  (1'b0),
    .src_in   (btn_async),
    .dest_clk (clk),
    .dest_out (btn)
  );

  always_ff @(posedge clk) begin
    rise <= 1'b0;
    if (rst) begin
      cnt   <= '0;
      level <= 1'b0;
    end else if (btn == level) begin
      cnt <= '0;
    end else if (cnt == CLKS - 1) begin
      cnt   <= '0;
      level <= btn;
      rise  <= btn;
    end else begin
      cnt <= cnt + 1'b1;
    end
  end

endmodule
