`timescale 1ns/1ps

module top (
    input  logic        CLK100MHZ,
    input  logic        btnU,
    input  logic        btnD,
    input  logic        btnC,        // reset only (NOT game Start)

    // External controller (PMOD JC)
    input  logic        ctrl_up,
    input  logic        ctrl_down,
    input  logic        ctrl_start,  // JC3 — reset
    input  logic        ctrl_a,      // JC4 — start game / pause
    output logic [3:0]  vgaRed,
    output logic [3:0]  vgaGreen,
    output logic [3:0]  vgaBlue,
    output logic        Hsync,
    output logic        Vsync,

    // Cartridge ROM (W25Q32 SPI Flash, PMOD JA) — used when instr_rom SIMULATION=0
    output logic        spi_cs_n,
    output logic        spi_clk,
    output logic        spi_mosi,
    input  logic        spi_miso,
    input  logic        cart_present
);

  // ------------------------------------------------------------------
  // Reset
  // ------------------------------------------------------------------
  logic rst;
  assign rst = btnC | ~ctrl_start;  // btnC or controller START button (active-low)

  localparam int CART_SIM = 0;
  wire cart_present_eff = (CART_SIM != 0) ? 1'b1 : cart_present;

  // ------------------------------------------------------------------
  // Controller debounce (20-bit counter @ 100 MHz ≈ 10 ms)
  // ------------------------------------------------------------------
  logic [19:0] db_up_cnt, db_dn_cnt, db_a_cnt;
  logic        db_up, db_dn, db_a;

  always_ff @(posedge CLK100MHZ) begin
    // Up
    if (ctrl_up != db_up) begin
      db_up_cnt <= db_up_cnt + 1;
      if (&db_up_cnt) db_up <= ctrl_up;
    end else db_up_cnt <= '0;
    // Down
    if (ctrl_down != db_dn) begin
      db_dn_cnt <= db_dn_cnt + 1;
      if (&db_dn_cnt) db_dn <= ctrl_down;
    end else db_dn_cnt <= '0;
    // A button (start/pause)
    if (ctrl_a != db_a) begin
      db_a_cnt <= db_a_cnt + 1;
      if (&db_a_cnt) db_a <= ctrl_a;
    end else db_a_cnt <= '0;
  end

  // Controller is active-low (pull-up resistors) — invert before merging
  wire btn_up    = btnU | ~db_up;
  wire btn_down  = btnD | ~db_dn;
  wire btn_start = ~db_a;  // A button now handles start/pause

  // ------------------------------------------------------------------
  // 25 MHz pixel strobe from 100 MHz clock
  // ------------------------------------------------------------------
  logic [1:0] div;
  logic       pix_stb;

  always_ff @(posedge CLK100MHZ) begin
    if (rst) div <= 2'b00;
    else     div <= div + 2'b01;
  end
  assign pix_stb = (div == 2'b00);

  // ------------------------------------------------------------------
  // VGA timing (640×480 @ 60 Hz)
  // ------------------------------------------------------------------
  logic [9:0] x, y;
  logic       active_video, frame_tick;

  vga_timing u_timing (
    .clk         (CLK100MHZ),
    .rst         (rst),
    .pix_stb     (pix_stb),
    .x           (x),
    .y           (y),
    .hsync       (Hsync),
    .vsync       (Vsync),
    .active_video(active_video),
    .frame_tick  (frame_tick)
  );

  // ------------------------------------------------------------------
  // CPU clock divider
  // 100 kHz = comfortable speed for game logic  (~100k instr/sec)
  // ------------------------------------------------------------------
  localparam int CPU_HZ  = 10_000;
  localparam int CPU_DIV = 100_000_000 / CPU_HZ;

  logic [$clog2(CPU_DIV)-1:0] cpu_cnt;
  logic cpu_step;

  always_ff @(posedge CLK100MHZ) begin
    if (rst) begin
      cpu_cnt  <= '0;
      cpu_step <= 1'b0;
    end else begin
      if (cpu_cnt == CPU_DIV-1) begin
        cpu_cnt  <= '0;
        cpu_step <= 1'b1;
      end else begin
        cpu_cnt  <= cpu_cnt + 1'b1;
        cpu_step <= 1'b0;
      end
    end
  end

  // ------------------------------------------------------------------
  // CPU + ROM + MMIO
  // ------------------------------------------------------------------
  logic [7:0]  cpu_pc;
  logic [15:0] cpu_inst;
  logic        cpu_we;
  logic [7:0]  cpu_addr;
  logic [15:0] cpu_wdata;
  logic [15:0] cpu_rdata;

  logic [9:0]  paddle_y_cpu;
  logic [1:0]  game_state_cpu;
  logic [15:0] score_cpu;

  logic        spr_we;
  logic [4:0]  spr_sel;
  logic        spr_xy;
  logic [15:0] spr_wdata;

  instr_rom #(.SIMULATION(0)) u_rom (
    .clk      (CLK100MHZ),
    .addr     (cpu_pc),
    .inst     (cpu_inst),
    .spi_cs_n (spi_cs_n),
    .spi_clk  (spi_clk),
    .spi_mosi (spi_mosi),
    .spi_miso (spi_miso)
  );

  cpu u_cpu (
    .clk      (CLK100MHZ),
    .rst      (rst),
    .step     (cpu_step),
    .pc       (cpu_pc),
    .inst     (cpu_inst),
    .mem_we   (cpu_we),
    .mem_addr (cpu_addr),
    .mem_wdata(cpu_wdata),
    .mem_rdata(cpu_rdata)
  );

  mmio u_mmio (
    .clk           (CLK100MHZ),
    .we            (cpu_we),
    .addr          (cpu_addr),
    .wdata         (cpu_wdata),
    .rdata         (cpu_rdata),
    .paddle_y_cpu  (paddle_y_cpu),
    .game_state_cpu(game_state_cpu),
    .score_cpu     (score_cpu),
    .ball_x_hw     (ball_x),
    .ball_y_hw     (ball_y),
    .btnU          (btn_up),
    .btnD          (btn_down),
    .btnA          (1'b0),
    .btnB          (1'b0),
    .btnStart      (btn_start),
    .spr_we        (spr_we),
    .spr_sel       (spr_sel),
    .spr_xy        (spr_xy),
    .spr_wdata     (spr_wdata),
    .col_hit       (col_hit)
  );

  // ------------------------------------------------------------------
  // GPU — sprite engine
  // ------------------------------------------------------------------
  logic [3:0]  gpu_r, gpu_g, gpu_b;
  logic [31:1] col_hit;

  gpu u_gpu (
    .clk      (CLK100MHZ),
    .rst      (rst),
    .spr_we   (spr_we),
    .spr_sel  (spr_sel),
    .spr_xy   (spr_xy),
    .spr_wdata(spr_wdata),
    .px_x     (x),
    .px_y     (y),
    .active   (active_video),
    .red      (gpu_r),
    .green    (gpu_g),
    .blue     (gpu_b),
    .col_hit  (col_hit)
  );

  // ------------------------------------------------------------------
  // Pong physics (hardware — ball, AI paddle)
  // ------------------------------------------------------------------
  localparam int SCREEN_W  = 640;
  localparam int SCREEN_H  = 480;
  localparam int PADDLE_X  = 20;
  localparam int PADDLE_W  = 10;
  localparam int PADDLE_H  = 80;
  localparam int AI_X      = SCREEN_W - 20 - PADDLE_W;
  localparam int AI_SPEED  = 2;
  localparam int BALL_SIZE = 8;

  typedef enum logic [2:0] { TITLE=3'b000, PLAY=3'b001, GAMEOVER=3'b010, PAUSE=3'b011 } game_state_t;
  game_state_t game_state = TITLE;

  // Hardware score counters — incremented by ball physics, not CPU
  logic [3:0]         hw_score_l  = 4'd0;   // left  player score
  logic [3:0]         hw_score_r  = 4'd0;   // right player score

  logic [9:0]         paddle_y    = 10'd200;
  logic [9:0]         ai_paddle_y = 10'd200;
  logic [9:0]         ball_x      = 10'd320;
  logic [9:0]         ball_y      = 10'd240;
  logic signed [10:0] ball_vx     = 11'sd3;
  logic signed [10:0] ball_vy     = 11'sd2;
  logic signed [11:0] next_bx, next_by;

  always_ff @(posedge CLK100MHZ) begin
    if (rst) begin
      game_state  <= TITLE;
      paddle_y    <= 10'd200;
      ai_paddle_y <= 10'd200;
      ball_x      <= 10'd320;
      ball_y      <= 10'd240;
      ball_vx     <= 11'sd3;
      ball_vy     <= 11'sd2;
      hw_score_l  <= 4'd0;
      hw_score_r  <= 4'd0;

    end else if (frame_tick) begin

      if (game_state == TITLE) begin
        if (btn_up || btn_down || btn_start) game_state <= PLAY;
        paddle_y    <= 10'd200;
        ai_paddle_y <= 10'd200;
        ball_x      <= 10'd320;
        ball_y      <= 10'd240;
        ball_vx     <= 11'sd3;
        ball_vy     <= 11'sd2;
        hw_score_l  <= 4'd0;
        hw_score_r  <= 4'd0;

      end else if (game_state == GAMEOVER) begin
        if (btn_up || btn_down || btn_start) game_state <= TITLE;

      end else if (game_state == PAUSE) begin
        if (btn_start) game_state <= PLAY;

      end else begin
        // PLAY — check for pause
        if (btn_start) begin
          game_state <= PAUSE;
        end else begin
        // CPU controls player paddle
        if (paddle_y_cpu > 10'(SCREEN_H - PADDLE_H))
          paddle_y <= 10'(SCREEN_H - PADDLE_H);
        else
          paddle_y <= paddle_y_cpu;

        // AI only reacts when ball is moving toward it and outside a 20px deadband
        if (ball_vx > 0) begin
          if (ball_y + (BALL_SIZE/2) < ai_paddle_y + (PADDLE_H/2) - 10) begin
            if (ai_paddle_y >= 10'(AI_SPEED)) ai_paddle_y <= ai_paddle_y - 10'(AI_SPEED);
            else                              ai_paddle_y <= 10'd0;
          end else if (ball_y + (BALL_SIZE/2) > ai_paddle_y + (PADDLE_H/2) + 10) begin
            if (ai_paddle_y + 10'(AI_SPEED) <= 10'(SCREEN_H - PADDLE_H))
              ai_paddle_y <= ai_paddle_y + 10'(AI_SPEED);
            else
              ai_paddle_y <= 10'(SCREEN_H - PADDLE_H);
          end
        end


        // Ball movement
        next_bx = $signed({1'b0, ball_x}) + ball_vx;
        next_by = $signed({1'b0, ball_y}) + ball_vy;

        if (next_bx <= 0 || next_bx >= (SCREEN_W - BALL_SIZE)) begin
          // Score: ball off left  → right player scores
          //        ball off right → left  player scores
          if (next_bx <= 0) begin
            if (hw_score_r < 4'd9) hw_score_r <= hw_score_r + 4'd1;
          end else begin
            if (hw_score_l < 4'd9) hw_score_l <= hw_score_l + 4'd1;
          end
          ball_x  <= 10'd320;
          ball_y  <= 10'd240;
          ball_vx <= (ball_vx > 0) ? -11'sd3 : 11'sd3;
          ball_vy <= 11'sd2;
        end else begin
          ball_x <= next_bx[9:0];
          if      (next_by <= 0)                        begin ball_y <= 10'd0;                     ball_vy <= -ball_vy; end
          else if (next_by >= (SCREEN_H - BALL_SIZE))   begin ball_y <= 10'(SCREEN_H - BALL_SIZE); ball_vy <= -ball_vy; end
          else                                                ball_y <= next_by[9:0];
        end

        // Left paddle bounce — speed up by 1, cap at 8
        if (ball_vx < 0 &&
            ball_x <= 10'(PADDLE_X + PADDLE_W) && ball_x >= 10'(PADDLE_X) &&
            ball_y + 10'(BALL_SIZE) > paddle_y  && ball_y < paddle_y + 10'(PADDLE_H)) begin
          ball_x  <= 10'(PADDLE_X + PADDLE_W);
          ball_vx <= (-ball_vx < 11'sd8) ? -ball_vx + 11'sd1 : 11'sd8;
        end

        // Right paddle bounce — speed up by 1, cap at 8
        if (ball_vx > 0 &&
            ball_x + 10'(BALL_SIZE) >= 10'(AI_X) &&
            ball_x + 10'(BALL_SIZE) <= 10'(AI_X + PADDLE_W) &&
            ball_y + 10'(BALL_SIZE) > ai_paddle_y &&
            ball_y < ai_paddle_y + 10'(PADDLE_H)) begin
          ball_x  <= 10'(AI_X - BALL_SIZE);
          ball_vx <= (-ball_vx > -11'sd8) ? -ball_vx - 11'sd1 : -11'sd8;
        end

        // Win condition: first to 5 points
        if (hw_score_l >= 4'd5 || hw_score_r >= 4'd5)
          game_state <= GAMEOVER;
        end // end else (not paused)
      end
    end
  end

  // ------------------------------------------------------------------
  // Font ROM (combinational — 22 chars × 8×8 bits, synthesizes to LUTs)
  //
  // Indices: 0-9=digits  10=P 11=O 12=N 13=G 14=R 15=E 16=S 17=sp 18=U 19=A 20=M 21=V
  // Encoding: 64-bit value, row 0 at [63:56], bit 7 = leftmost pixel.
  // ------------------------------------------------------------------
  function automatic logic char_pixel(
    input logic [4:0] ch,
    input logic [2:0] row,
    input logic [2:0] col
  );
    logic [63:0] bmp;
    logic [7:0]  rowbyte;
    case (ch)
      5'd0:  bmp = 64'h7CC6CEDEF6E67C00; // 0
      5'd1:  bmp = 64'h307030303030FC00; // 1
      5'd2:  bmp = 64'h78CC0C3860C0FC00; // 2
      5'd3:  bmp = 64'h78CC0C380CCC7800; // 3
      5'd4:  bmp = 64'h1C3C6CCCFE0C0C00; // 4
      5'd5:  bmp = 64'hFCC0F80C0CCC7800; // 5
      5'd6:  bmp = 64'h3860C0F8CCCC7800; // 6
      5'd7:  bmp = 64'hFCCC0C1830303000; // 7
      5'd8:  bmp = 64'h78CCCC78CCCC7800; // 8
      5'd9:  bmp = 64'h78CCCC7C0C187000; // 9
      5'd10: bmp = 64'hF8CCCCF8C0C0C000; // P
      5'd11: bmp = 64'h78CCCCCCCCCC7800; // O
      5'd12: bmp = 64'hC6E6F6DECEC6C600; // N
      5'd13: bmp = 64'h3C66C6C0DEC67C00; // G
      5'd14: bmp = 64'hFCCCCCFCD8CCCC00; // R
      5'd15: bmp = 64'hFEC0C0FCC0C0FE00; // E
      5'd16: bmp = 64'h7CC6C07C06C67C00; // S
      5'd17: bmp = 64'h0000000000000000; // (space)
      5'd18: bmp = 64'hC6C6C6C6C6C67C00; // U
      5'd19: bmp = 64'h386CC6C6FEC6C600; // A
      5'd20: bmp = 64'hC6EEFED6C6C6C600; // M
      5'd21: bmp = 64'hC6C6C6C6C66C3800; // V
      5'd22: bmp = 64'hFC3030303030FC00; // I
      5'd23: bmp = 64'hFE30303030303000; // T
      5'd24: bmp = 64'h78CCC0C0C0CC7800; // C
      default: bmp = 64'h0;
    endcase
    case (row)
      3'd0: rowbyte = bmp[63:56];
      3'd1: rowbyte = bmp[55:48];
      3'd2: rowbyte = bmp[47:40];
      3'd3: rowbyte = bmp[39:32];
      3'd4: rowbyte = bmp[31:24];
      3'd5: rowbyte = bmp[23:16];
      3'd6: rowbyte = bmp[15:8];
      3'd7: rowbyte = bmp[7:0];
    endcase
    char_pixel = rowbyte[3'd7 - col];  // bit 7 = leftmost pixel
  endfunction

  // ------------------------------------------------------------------
  // Pixel compositing
  //   Layer 0: background / title
  //   Layer 1: GPU sprites
  //   Layer 2: score digits (play mode)
  //   Layer 3: hardware shapes — paddles, ball (always on top)
  //
  // RGB is computed combinationally into vga_r/g/b, then registered
  // one clock before driving the output pins.  This pipeline stage
  // breaks the long comb path and gives the timing closure back.
  // ------------------------------------------------------------------
  logic [3:0] vga_r, vga_g, vga_b;
  logic gpu_hit;
  assign gpu_hit = (gpu_r != 0) || (gpu_g != 0) || (gpu_b != 0);

  logic draw_paddle, draw_ai, draw_ball, draw_center;
  assign draw_paddle = (x >= 10'(PADDLE_X))  && (x < 10'(PADDLE_X  + PADDLE_W)) &&
                       (y >= paddle_y)         && (y < paddle_y     + 10'(PADDLE_H));
  assign draw_ai     = (x >= 10'(AI_X))       && (x < 10'(AI_X     + PADDLE_W)) &&
                       (y >= ai_paddle_y)      && (y < ai_paddle_y  + 10'(PADDLE_H));
  assign draw_ball   = (x >= ball_x)           && (x < ball_x + 10'(BALL_SIZE)) &&
                       (y >= ball_y)            && (y < ball_y + 10'(BALL_SIZE));
  assign draw_center = (x >= 10'd318) && (x < 10'd322) && (y[3] == 1'b0);

  always_comb begin
    // Local variables declared at top of block (Vivado requirement)
    logic [2:0] t_row, t_col;
    logic [2:0] sc_row, sc_col;
    logic [4:0] sc_digit;
    logic [2:0] pr_row, pr_col;
    logic [3:0] pr_idx;
    logic [4:0] pr_ch;

    vga_r = 4'h0;
    vga_g = 4'h0;
    vga_b = 4'h0;

    // defaults to suppress latches
    t_row = 3'd0; t_col = 3'd0;
    sc_row = 3'd0; sc_col = 3'd0; sc_digit = 5'd0;
    pr_row = 3'd0; pr_col = 3'd0; pr_idx = 4'd0; pr_ch = 5'd17;

    if (active_video) begin

      // ===== NO CARTRIDGE SCREEN =====
      if (!cart_present_eff) begin

        vga_b = 4'h2;   // dark blue background

        // "NO CART" — 8× scale, y=[160,224), centered x=[96,544)
        if (y >= 10'd160 && y < 10'd224) begin
          t_row = 3'((y - 10'd160) >> 3);
          if (x >= 10'd96  && x < 10'd160) begin   // N
            t_col = 3'((x - 10'd96)  >> 3);
            if (char_pixel(5'd12, t_row, t_col)) begin vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF; end
          end
          if (x >= 10'd160 && x < 10'd224) begin   // O
            t_col = 3'((x - 10'd160) >> 3);
            if (char_pixel(5'd11, t_row, t_col)) begin vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF; end
          end
          if (x >= 10'd288 && x < 10'd352) begin   // C
            t_col = 3'((x - 10'd288) >> 3);
            if (char_pixel(5'd24, t_row, t_col)) begin vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF; end
          end
          if (x >= 10'd352 && x < 10'd416) begin   // A
            t_col = 3'((x - 10'd352) >> 3);
            if (char_pixel(5'd19, t_row, t_col)) begin vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF; end
          end
          if (x >= 10'd416 && x < 10'd480) begin   // R
            t_col = 3'((x - 10'd416) >> 3);
            if (char_pixel(5'd14, t_row, t_col)) begin vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF; end
          end
          if (x >= 10'd480 && x < 10'd544) begin   // T
            t_col = 3'((x - 10'd480) >> 3);
            if (char_pixel(5'd23, t_row, t_col)) begin vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF; end
          end
        end

        // "INSERT CART" — 2× scale, 11 chars × 16px = 176px, x=[232,408), y=[310,326)
        if (y >= 10'd310 && y < 10'd326 && x >= 10'd232 && x < 10'd408) begin
          pr_row = 3'((y  - 10'd310) >> 1);
          pr_idx = 4'((x  - 10'd232) >> 4);
          pr_col = 3'(((x - 10'd232) & 10'hF) >> 1);
          case (pr_idx)
            4'd0:  pr_ch = 5'd22; // I
            4'd1:  pr_ch = 5'd12; // N
            4'd2:  pr_ch = 5'd16; // S
            4'd3:  pr_ch = 5'd15; // E
            4'd4:  pr_ch = 5'd14; // R
            4'd5:  pr_ch = 5'd23; // T
            4'd6:  pr_ch = 5'd17; // (space)
            4'd7:  pr_ch = 5'd24; // C
            4'd8:  pr_ch = 5'd19; // A
            4'd9:  pr_ch = 5'd14; // R
            4'd10: pr_ch = 5'd23; // T
            default: pr_ch = 5'd17;
          endcase
          if (char_pixel(pr_ch, pr_row, pr_col)) begin
            vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'h0;
          end
        end

      // ===== TITLE SCREEN =====
      end else if (game_state == TITLE) begin

        vga_b = 4'h2;   // dark blue background

        // "PONG" — font scaled 8×, centered at x=[192,448)  y=[160,224)
        if (y >= 10'd160 && y < 10'd224) begin
          t_row = 3'((y - 10'd160) >> 3);

          if (x >= 10'd192 && x < 10'd256) begin   // P
            t_col = 3'((x - 10'd192) >> 3);
            if (char_pixel(5'd10, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
          if (x >= 10'd256 && x < 10'd320) begin   // O
            t_col = 3'((x - 10'd256) >> 3);
            if (char_pixel(5'd11, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
          if (x >= 10'd320 && x < 10'd384) begin   // N
            t_col = 3'((x - 10'd320) >> 3);
            if (char_pixel(5'd12, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
          if (x >= 10'd384 && x < 10'd448) begin   // G
            t_col = 3'((x - 10'd384) >> 3);
            if (char_pixel(5'd13, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
        end

        // "PRESS UP" — 2× scale, 8 chars × 16px = 128px, centered x=[256,384), y=[310,326)
        // chars: P(10) R(14) E(15) S(16) S(16) ' '(17) U(18) P(10)
        if (y >= 10'd310 && y < 10'd326 && x >= 10'd256 && x < 10'd384) begin
          pr_row = 3'((y  - 10'd310) >> 1);
          pr_idx = 4'((x  - 10'd256) >> 4);
          pr_col = 3'(((x - 10'd256) & 10'hF) >> 1);
          case (pr_idx)
            4'd0: pr_ch = 5'd10; // P
            4'd1: pr_ch = 5'd14; // R
            4'd2: pr_ch = 5'd15; // E
            4'd3: pr_ch = 5'd16; // S
            4'd4: pr_ch = 5'd16; // S
            4'd5: pr_ch = 5'd17; // (space)
            4'd6: pr_ch = 5'd18; // U
            4'd7: pr_ch = 5'd10; // P
            default: pr_ch = 5'd17;
          endcase
          if (char_pixel(pr_ch, pr_row, pr_col)) begin
            vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'h0;
          end
        end

      // ===== GAME OVER SCREEN =====
      end else if (game_state == GAMEOVER) begin

        vga_r = 4'h1;   // dark red background

        // "GAME" — 8× scale, x=[192,448)  y=[100,164)
        if (y >= 10'd100 && y < 10'd164) begin
          t_row = 3'((y - 10'd100) >> 3);
          if (x >= 10'd192 && x < 10'd256) begin   // G
            t_col = 3'((x - 10'd192) >> 3);
            if (char_pixel(5'd13, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
          if (x >= 10'd256 && x < 10'd320) begin   // A
            t_col = 3'((x - 10'd256) >> 3);
            if (char_pixel(5'd19, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
          if (x >= 10'd320 && x < 10'd384) begin   // M
            t_col = 3'((x - 10'd320) >> 3);
            if (char_pixel(5'd20, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
          if (x >= 10'd384 && x < 10'd448) begin   // E
            t_col = 3'((x - 10'd384) >> 3);
            if (char_pixel(5'd15, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
        end

        // "OVER" — 8× scale, x=[192,448)  y=[200,264)
        if (y >= 10'd200 && y < 10'd264) begin
          t_row = 3'((y - 10'd200) >> 3);
          if (x >= 10'd192 && x < 10'd256) begin   // O
            t_col = 3'((x - 10'd192) >> 3);
            if (char_pixel(5'd11, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
          if (x >= 10'd256 && x < 10'd320) begin   // V
            t_col = 3'((x - 10'd256) >> 3);
            if (char_pixel(5'd21, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
          if (x >= 10'd320 && x < 10'd384) begin   // E
            t_col = 3'((x - 10'd320) >> 3);
            if (char_pixel(5'd15, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
          if (x >= 10'd384 && x < 10'd448) begin   // R
            t_col = 3'((x - 10'd384) >> 3);
            if (char_pixel(5'd14, t_row, t_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
            end
          end
        end

        // Final scores — 4× scale (32×32 px), y=[310,342)
        //   Left  score: x=[272,304)   Right score: x=[336,368)
        //   Winner's digit is gold; loser's is dim orange
        if (y >= 10'd310 && y < 10'd342) begin
          sc_row = 3'((y - 10'd310) >> 2);
          if (x >= 10'd272 && x < 10'd304) begin
            sc_digit = {1'b0, hw_score_l};
            sc_col   = 3'((x - 10'd272) >> 2);
            if (char_pixel(sc_digit, sc_row, sc_col)) begin
              vga_r = 4'hF;
              vga_g = (hw_score_l >= hw_score_r) ? 4'hA : 4'h4;
              vga_b = 4'h0;
            end
          end
          if (x >= 10'd336 && x < 10'd368) begin
            sc_digit = {1'b0, hw_score_r};
            sc_col   = 3'((x - 10'd336) >> 2);
            if (char_pixel(sc_digit, sc_row, sc_col)) begin
              vga_r = 4'hF;
              vga_g = (hw_score_r >= hw_score_l) ? 4'hA : 4'h4;
              vga_b = 4'h0;
            end
          end
        end

        // "PRESS UP" — 2× scale, y=[400,416), x=[256,384)
        if (y >= 10'd400 && y < 10'd416 && x >= 10'd256 && x < 10'd384) begin
          pr_row = 3'((y  - 10'd400) >> 1);
          pr_idx = 4'((x  - 10'd256) >> 4);
          pr_col = 3'(((x - 10'd256) & 10'hF) >> 1);
          case (pr_idx)
            4'd0: pr_ch = 5'd10; // P
            4'd1: pr_ch = 5'd14; // R
            4'd2: pr_ch = 5'd15; // E
            4'd3: pr_ch = 5'd16; // S
            4'd4: pr_ch = 5'd16; // S
            4'd5: pr_ch = 5'd17; // (space)
            4'd6: pr_ch = 5'd18; // U
            4'd7: pr_ch = 5'd10; // P
            default: pr_ch = 5'd17;
          endcase
          if (char_pixel(pr_ch, pr_row, pr_col)) begin
            vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'h0;
          end
        end

      // ===== PAUSE SCREEN =====
      end else if (game_state == PAUSE) begin

        vga_r = 4'h1; vga_g = 4'h1; vga_b = 4'h1;  // dark grey overlay

        // "PAUSE" — 4× scale, 5 chars × 32px = 160px, centered x=[240,400) y=[224,256)
        if (y >= 10'd224 && y < 10'd256 && x >= 10'd240 && x < 10'd400) begin
          pr_row = 3'((y  - 10'd224) >> 2);
          pr_idx = 4'((x  - 10'd240) >> 5);
          pr_col = 3'(((x - 10'd240) & 10'h1F) >> 2);
          case (pr_idx)
            4'd0: pr_ch = 5'd10;  // P
            4'd1: pr_ch = 5'd19;  // A
            4'd2: pr_ch = 5'd18;  // U
            4'd3: pr_ch = 5'd16;  // S
            4'd4: pr_ch = 5'd15;  // E
            default: pr_ch = 5'd17;
          endcase
          if (char_pixel(pr_ch, pr_row, pr_col)) begin
            vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
          end
        end

      // ===== PLAY SCREEN =====
      end else begin

        vga_r = 4'h3;   // dark red play background

        // Layer 0: dashed center line
        if (draw_center) begin
          vga_r = 4'h4; vga_g = 4'h4; vga_b = 4'h4;
        end

        // Layer 1: GPU sprites
        if (gpu_hit) begin
          vga_r = gpu_r;
          vga_g = gpu_g;
          vga_b = gpu_b;
        end

        // Layer 2: score digits  (2× scale → 16×16 px)
        //   Left  score: x=[300,316)  y=[4,20)
        //   Right score: x=[324,340)  y=[4,20)
        if (y >= 10'd4 && y < 10'd20) begin
          sc_row = 3'((y - 10'd4) >> 1);

          if (x >= 10'd300 && x < 10'd316) begin
            sc_digit = {1'b0, hw_score_l};
            sc_col   = 3'((x - 10'd300) >> 1);
            if (char_pixel(sc_digit, sc_row, sc_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'h0;
            end
          end

          if (x >= 10'd324 && x < 10'd340) begin
            sc_digit = {1'b0, hw_score_r};
            sc_col   = 3'((x - 10'd324) >> 1);
            if (char_pixel(sc_digit, sc_row, sc_col)) begin
              vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'h0;
            end
          end
        end

        // Layer 3: hardware shapes always on top
        if (draw_paddle || draw_ai || draw_ball) begin
          vga_r = 4'hF; vga_g = 4'hF; vga_b = 4'hF;
        end

      end
    end
  end

  // Pipeline register: breaks the long comb path, gives timing closure
  always_ff @(posedge CLK100MHZ) begin
    vgaRed   <= vga_r;
    vgaGreen <= vga_g;
    vgaBlue  <= vga_b;
  end

endmodule
