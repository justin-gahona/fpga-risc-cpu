// =============================================================
// mmio.sv  —  Memory-Mapped I/O
// =============================================================
//
// System Memory Map (8-bit address, 16-bit data words)
// -------------------------------------------------------
// Addr       | Name        | Dir   | Description
// -----------+-------------+-------+---------------------
// 0x00       | PADDLE_Y    | R/W   | Player paddle Y (0–400)
// 0x01       | BALL_X      | R     | Ball X (driven by top.sv)
// 0x02       | BALL_Y      | R     | Ball Y (driven by top.sv)
// 0x03       | GAME_STATE  | R/W   | 0=TITLE 1=PLAY 2=GAMEOVER
// 0x04       | SCORE       | R/W   | [15:8]=right [7:0]=left
// 0x10       | BUTTONS     | R     | [4]=start [3]=B [2]=A [1]=D [0]=U
// 0x40+i*2   | SPR_X[i]   | R/W   | Sprite i X  (0 = disabled)
// 0x41+i*2   | SPR_Y[i]   | R/W   | Sprite i Y
//   i = 0..31  →  addresses 0x40–0x7F
// -------------------------------------------------------

module mmio (
  input  logic        clk,
  input  logic        we,
  input  logic [7:0]  addr,
  input  logic [15:0] wdata,
  output logic [15:0] rdata,

  // --- CPU-facing register outputs ---
  output logic [9:0]  paddle_y_cpu,
  output logic [1:0]  game_state_cpu,
  output logic [15:0] score_cpu,

  // --- Hardware inputs (driven by top.sv physics) ---
  input  logic [9:0]  ball_x_hw,
  input  logic [9:0]  ball_y_hw,

  // --- Controller inputs ---
  input  logic        btnU,
  input  logic        btnD,
  input  logic        btnA,
  input  logic        btnB,
  input  logic        btnStart,

  // --- Sprite table write port → GPU ---
  output logic        spr_we,
  output logic [4:0]  spr_sel,    // sprite index 0-31
  output logic        spr_xy,     // 0=X word, 1=Y word
  output logic [15:0] spr_wdata,

  // --- Hardware collision vector (from GPU) ---
  // 0x06: col_hit[15:1]  sprites  1-15
  // 0x07: col_hit[31:16] sprites 16-31
  input  logic [31:1] col_hit
);

  localparam int SCREEN_H = 480;
  localparam int PADDLE_H = 80;
  localparam int MAX_Y    = SCREEN_H - PADDLE_H;  // 400

  // ---- Writable system registers ----
  logic [9:0]  paddle_reg     = 10'd200;
  logic [1:0]  game_state_reg = 2'd0;
  logic [15:0] score_reg      = 16'd0;

  // ---- Sprite table write decode ----
  // Addresses 0x40–0x7F: addr[7:6]==2'b01
  // spr_sel = addr[5:1]   (sprite index)
  // spr_xy  = addr[0]     (0=X, 1=Y)
  assign spr_we    = we && (addr[7:6] == 2'b01);
  assign spr_sel   = addr[5:1];
  assign spr_xy    = addr[0];
  assign spr_wdata = wdata;

  // ---- System register writes ----
  always_ff @(posedge clk) begin
    if (we && (addr[7:6] != 2'b01)) begin   // not a sprite write
      case (addr)
        8'h00: begin
          if      (wdata[15])              paddle_reg <= 10'd0;
          else if (wdata[9:0] > MAX_Y[9:0]) paddle_reg <= MAX_Y[9:0];
          else                              paddle_reg <= wdata[9:0];
        end
        8'h03: game_state_reg <= wdata[1:0];
        8'h04: score_reg      <= wdata;
      endcase
    end
  end

  // ---- Read mux ----
  always_comb begin
    case (addr)
      8'h00:   rdata = {6'd0, paddle_reg};
      8'h01:   rdata = {6'd0, ball_x_hw};
      8'h02:   rdata = {6'd0, ball_y_hw};
      8'h03:   rdata = {14'd0, game_state_reg};
      8'h04:   rdata = score_reg;
      8'h06:   rdata = {1'b0,  col_hit[15:1]};   // sprites  1-15
      8'h07:   rdata = col_hit[31:16];            // sprites 16-31
      8'h10:   rdata = {11'd0, btnStart, btnB, btnA, btnD, btnU};
      default: rdata = 16'd0;
    endcase
  end

  assign paddle_y_cpu   = paddle_reg;
  assign game_state_cpu = game_state_reg;
  assign score_cpu      = score_reg;

endmodule
