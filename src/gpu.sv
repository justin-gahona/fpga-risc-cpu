// =============================================================
// gpu.sv  —  Hardware Sprite Engine with Tile Patterns
// =============================================================
//
// 32 sprites, each 8×8 pixels.
//
// SPR_X word  (MMIO 0x40+i*2):  [9:0]  = X   (0 = disabled)
// SPR_Y word  (MMIO 0x41+i*2):  [15:13]= tile_idx  (0–7)
//                                [12:10]= color_idx (0–7)
//                                [8:0]  = Y
//
// Tile patterns (8 built-in, all combinational LUT ROM):
//   0 = solid square      4 = diamond
//   1 = outline square    5 = smiley face
//   2 = X / crosshair     6 = heart
//   3 = plus / cross      7 = star
//
// Color palette (8 colors):
//   0=white  1=red   2=green   3=blue
//   4=yellow 5=magenta 6=cyan  7=orange
//
// Pixel output is all-zero when no sprite hits (transparent).
// Collision: col_hit[i]=1 when sprite[i] bbox overlaps sprite[0].
// =============================================================

module gpu (
  input  logic        clk,
  input  logic        rst,

  // Sprite table write port (from MMIO)
  input  logic        spr_we,
  input  logic [4:0]  spr_sel,    // sprite index 0–31
  input  logic        spr_xy,     // 0 = write X word, 1 = write Y word
  input  logic [15:0] spr_wdata,

  // VGA scan position
  input  logic [9:0]  px_x,
  input  logic [9:0]  px_y,
  input  logic        active,

  // Pixel output  (all zeros = transparent)
  output logic [3:0]  red,
  output logic [3:0]  green,
  output logic [3:0]  blue,

  // Hardware collision: sprite[i] bbox overlaps sprite[0]
  output logic [31:1] col_hit
);

  localparam int N  = 32;
  localparam int SW = 8;
  localparam int SH = 8;

  // ---------- Sprite table (registers) ----------
  logic [9:0] sx [0:N-1];   // X  (0 = disabled)
  logic [8:0] sy [0:N-1];   // Y
  logic [2:0] st [0:N-1];   // tile index
  logic [2:0] sc [0:N-1];   // color index

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < N; i++) begin
        sx[i] <= '0;  sy[i] <= '0;
        st[i] <= '0;  sc[i] <= '0;
      end
    end else if (spr_we) begin
      if (!spr_xy) begin
        sx[spr_sel] <= spr_wdata[9:0];
      end else begin
        sy[spr_sel] <= spr_wdata[8:0];
        st[spr_sel] <= spr_wdata[15:13];
        sc[spr_sel] <= spr_wdata[12:10];
      end
    end
  end

  // ---------- Tile ROM (combinational — fits in LUTs) ----------
  // Each tile is 8 rows packed as a 64-bit value.
  // Row 0 at bits [63:56], row 7 at bits [7:0].
  // Within each byte: bit 7 = leftmost pixel.
  function automatic logic [7:0] tile_row(
    input logic [2:0] tile_idx,
    input logic [2:0] row
  );
    logic [63:0] bmp;
    case (tile_idx)
      3'd0: bmp = 64'hFFFFFFFFFFFFFFFF; // solid square
      3'd1: bmp = 64'hFF818181818181FF; // outline square
      3'd2: bmp = 64'h8142241818244281; // X / crosshair
      3'd3: bmp = 64'h183C3CFFFF3C3C18; // plus / cross (filled)
      3'd4: bmp = 64'h183C7EFFFF7E3C18; // diamond
      3'd5: bmp = 64'h3C42A581BD99423C; // smiley face
      3'd6: bmp = 64'h6666FFFF7E3C1800; // heart
      3'd7: bmp = 64'h18DBE77E7EE7DB18; // star / asterisk
      default: bmp = 64'hFFFFFFFFFFFFFFFF;
    endcase
    case (row)
      3'd0: tile_row = bmp[63:56];
      3'd1: tile_row = bmp[55:48];
      3'd2: tile_row = bmp[47:40];
      3'd3: tile_row = bmp[39:32];
      3'd4: tile_row = bmp[31:24];
      3'd5: tile_row = bmp[23:16];
      3'd6: tile_row = bmp[15:8];
      3'd7: tile_row = bmp[7:0];
    endcase
  endfunction

  // ---------- Color palette ----------
  function automatic logic [11:0] palette(input logic [2:0] idx);
    case (idx)
      3'd0: palette = 12'hFFF; // white
      3'd1: palette = 12'hF44; // red
      3'd2: palette = 12'h4F4; // green
      3'd3: palette = 12'h44F; // blue
      3'd4: palette = 12'hFF4; // yellow
      3'd5: palette = 12'hF4F; // magenta
      3'd6: palette = 12'h4FF; // cyan
      3'd7: palette = 12'hF84; // orange
    endcase
  endfunction

  // ---------- Per-sprite pixel hit (bbox + tile pixel) ----------
  logic [N-1:0] spr_hit;

  genvar gi;
  generate
    for (gi = 0; gi < N; gi++) begin : SPR_HIT
      wire        en    = (sx[gi] != 10'd0);
      wire        x_ok  = (px_x >= sx[gi]) && (px_x < sx[gi] + 10'(SW));
      wire        y_ok  = (px_y >= {1'b0, sy[gi]}) && (px_y < {1'b0, sy[gi]} + 10'(SH));
      wire [2:0]  t_col = px_x[2:0] - sx[gi][2:0];  // 0–7 within sprite
      wire [2:0]  t_row = px_y[2:0] - sy[gi][2:0];  // 0–7 within sprite
      wire [7:0]  tdata = tile_row(st[gi], t_row);
      wire        t_px  = tdata[3'd7 - t_col];       // bit 7 = leftmost

      assign spr_hit[gi] = en && x_ok && y_ok && t_px;
    end
  endgenerate

  // ---------- Priority pixel output ----------
  // Descending loop: lowest sprite index wins.
  always_comb begin
    logic [11:0] pal_tmp;
    red   = 4'h0;
    green = 4'h0;
    blue  = 4'h0;
    pal_tmp = 12'h0;
    if (active) begin
      for (int i = N-1; i >= 0; i--) begin
        if (spr_hit[i]) begin
          pal_tmp = palette(sc[i]);
          red   = pal_tmp[11:8];
          green = pal_tmp[7:4];
          blue  = pal_tmp[3:0];
        end
      end
    end
  end

  // ---------- Collision detection ----------
  generate
    for (gi = 1; gi < N; gi++) begin : COL_DET
      assign col_hit[gi] =
        (sx[gi] != 10'd0) && (sx[0] != 10'd0) &&
        (sx[gi]          <  sx[0]          + 10'(SW)) &&
        (sx[gi]          + 10'(SW)         >  sx[0])  &&
        ({1'b0, sy[gi]}  < {1'b0, sy[0]}   + 10'(SH)) &&
        ({1'b0, sy[gi]}  + 10'(SH)         > {1'b0, sy[0]});
    end
  endgenerate

endmodule
