`timescale 1ns/1ps
// =============================================================
// instr_rom.sv  —  Instruction ROM with W25Q32 SPI cartridge
// =============================================================
//
// SIMULATION=1 (default):
//   BRAM inference via $readmemh("game.mem") — for development.
//   SPI pins driven to safe idle values.
//
// SIMULATION=0  (set for demo day hot-swap):
//   Game code lives on W25Q32 SPI NOR Flash cartridge.
//   SPI Mode 0 (CPOL=0, CPHA=0), 12.5 MHz clock.
//
//   Each fetch = 48 SPI clocks:
//     TX: 0x03 READ cmd (8 bits) + 24-bit byte address (2×PC)
//     RX: high byte then low byte of 16-bit instruction
//
//   W25Q32 DIP-8 wiring:
//     Pin 1 (/CS)   → spi_cs_n   (PMOD JA pin 1)
//     Pin 2 (DO)    → spi_miso   (PMOD JA pin 4)
//     Pin 3 (/WP)   → 3.3V  (tie high on PCB)
//     Pin 4 (GND)   → GND
//     Pin 5 (DI)    → spi_mosi   (PMOD JA pin 3)
//     Pin 6 (CLK)   → spi_clk    (PMOD JA pin 2)
//     Pin 7 (/HOLD) → 3.3V  (tie high on PCB)
//     Pin 8 (VCC)   → 3.3V
// =============================================================

module instr_rom #(
  parameter int SIMULATION = 1
) (
  input  logic        clk,
  input  logic [7:0]  addr,
  output logic [15:0] inst,

  // W25Q32 SPI interface
  output logic        spi_cs_n,
  output logic        spi_clk,
  output logic        spi_mosi,
  input  logic        spi_miso
);

  generate

    // ----------------------------------------------------------
    // Simulation / development path — BRAM + $readmemh
    // ----------------------------------------------------------
    if (SIMULATION != 0) begin : g_sim

      (* ram_style = "block" *) logic [15:0] rom [0:255];
      initial $readmemh("game.mem", rom);

      always_ff @(posedge clk)
        inst <= rom[addr];

      assign spi_cs_n = 1'b1;
      assign spi_clk  = 1'b0;
      assign spi_mosi = 1'b0;

    end else begin : g_cart

      // ----------------------------------------------------------
      // W25Q32 SPI NOR Flash — Mode 0 (CPOL=0, CPHA=0), 12.5 MHz
      //
      // 48-bit transaction layout in shift register sr[47:0]:
      //   sr[47:40] = 0x03              (READ command)
      //   sr[39:16] = {15'b0, addr, 1'b0}  (byte address = 2×PC)
      //   sr[15: 0] = 0x0000            (dummy TX — RX phase)
      //
      // Phase counter (ph 0-7) per SPI bit:
      //   ph=3 → CLK rises, sample MISO (bits 32-47 only)
      //   ph=7 → CLK falls, shift sr, set next MOSI
      // ----------------------------------------------------------
      typedef enum logic [1:0] {
        S_FETCH = 2'd0,
        S_TX    = 2'd1,
        S_DONE  = 2'd2
      } state_t;

      state_t      state    = S_FETCH;
      logic [2:0]  ph       = '0;
      logic [5:0]  bit_cnt  = '0;
      logic [7:0]  addr_lat = '0;
      logic [47:0] sr       = '0;
      logic [15:0] rx       = '0;
      logic [15:0] inst_r   = '0;

      logic spi_clk_r  = 1'b0;
      logic spi_mosi_r = 1'b0;
      logic spi_cs_r   = 1'b1;

      assign inst     = inst_r;
      assign spi_clk  = spi_clk_r;
      assign spi_mosi = spi_mosi_r;
      assign spi_cs_n = spi_cs_r;

      always_ff @(posedge clk) begin
        case (state)

          S_FETCH: begin
            addr_lat   <= addr;
            sr         <= {8'h03, 15'b0, addr[7:0], 1'b0, 16'h0000};
            spi_cs_r   <= 1'b0;
            spi_mosi_r <= 1'b0;   // MSB of 0x03 = 0
            ph         <= '0;
            bit_cnt    <= '0;
            rx         <= '0;
            state      <= S_TX;
          end

          S_TX: begin
            ph <= ph + 3'd1;

            if (ph == 3'd3) begin
              spi_clk_r <= 1'b1;
              if (bit_cnt >= 6'd32)
                rx <= {rx[14:0], spi_miso};   // sample MISO MSB-first
            end

            if (ph == 3'd7) begin
              spi_clk_r <= 1'b0;
              ph        <= '0;
              if (bit_cnt == 6'd47) begin
                inst_r   <= rx;
                spi_cs_r <= 1'b1;
                state    <= S_DONE;
              end else begin
                sr         <= {sr[46:0], 1'b0};
                spi_mosi_r <= sr[46];
                bit_cnt    <= bit_cnt + 6'd1;
              end
            end
          end

          S_DONE: begin
            if (addr != addr_lat)
              state <= S_FETCH;
          end

          default: state <= S_FETCH;

        endcase
      end

    end // g_cart

  endgenerate

endmodule
