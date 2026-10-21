`timescale 1ns / 1ps
// Button synchronizer and debouncer. `level` follows the button once it has
// been stable for CYCLES clocks; `press` pulses for one cycle on each press.
module debounce #(
    parameter int CYCLES = 1_000_000      // 10 ms at 100 MHz
) (
    input  logic clk,
    input  logic btn,
    output logic level,
    output logic press
);
    logic btn_s;
    logic level_r = 1'b0;
    logic press_r = 1'b0;

    assign level = level_r;
    assign press = press_r;

    xpm_cdc_single #(
        .DEST_SYNC_FF  (2),
        .INIT_SYNC_FF  (1),
        .SRC_INPUT_REG (0)
    ) u_sync (
        .src_clk  (1'b0),
        .src_in   (btn),
        .dest_clk (clk),
        .dest_out (btn_s)
    );

    logic [$clog2(CYCLES+1)-1:0] cnt = '0;

    always_ff @(posedge clk) begin
        press_r <= 1'b0;
        if (btn_s == level_r) begin
            cnt <= '0;
        end else if (cnt == CYCLES - 1) begin
            cnt     <= '0;
            level_r <= btn_s;
            press_r <= btn_s;
        end else begin
            cnt <= cnt + 1;
        end
    end
endmodule
