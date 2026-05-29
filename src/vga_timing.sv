`timescale 1ns / 1ps

module vga_timing (
    input  logic       clk,
    input  logic       rst,
    input  logic       pix_stb,
    output logic [9:0] x,
    output logic [9:0] y,
    output logic       hsync,
    output logic       vsync,
    output logic       active_video,
    output logic       frame_tick
);

    localparam int H_VISIBLE = 640;
    localparam int H_FRONT   = 16;
    localparam int H_SYNC    = 96;
    localparam int H_BACK    = 48;
    localparam int H_TOTAL   = 800;

    localparam int V_VISIBLE = 480;
    localparam int V_FRONT   = 10;
    localparam int V_SYNC    = 2;
    localparam int V_BACK    = 33;
    localparam int V_TOTAL   = 525;

    logic [9:0] hcnt = 0;
    logic [9:0] vcnt = 0;

    always_ff @(posedge clk) begin
        if (rst) begin
            hcnt <= 0;
            vcnt <= 0;
        end
        else if (pix_stb) begin
            if (hcnt == H_TOTAL-1) begin
                hcnt <= 0;

                if (vcnt == V_TOTAL-1)
                    vcnt <= 0;
                else
                    vcnt <= vcnt + 1;

            end else begin
                hcnt <= hcnt + 1;
            end
        end
    end

    assign x = hcnt;
    assign y = vcnt;

    assign active_video = (hcnt < H_VISIBLE) && (vcnt < V_VISIBLE);

    assign hsync = ~((hcnt >= (H_VISIBLE + H_FRONT)) &&
                     (hcnt <  (H_VISIBLE + H_FRONT + H_SYNC)));

    assign vsync = ~((vcnt >= (V_VISIBLE + V_FRONT)) &&
                     (vcnt <  (V_VISIBLE + V_FRONT + V_SYNC)));

    assign frame_tick = pix_stb && (hcnt == 0) && (vcnt == 0);

endmodule