# Pong FPGA

A hardware Pong game implemented in SystemVerilog for the Basys 3 FPGA board, featuring a custom 16-bit RISC CPU, a hardware sprite engine, VGA output, and a physical SPI cartridge interface.

## Architecture

The design splits game logic between hardware and firmware:

- **Hardware (100 MHz)** — VGA timing, ball physics, AI paddle, scoring, pixel compositing
- **CPU firmware (10 kHz)** — sprite management and player paddle input, running on a custom RISC CPU

### Modules

| File | Description |
|---|---|
| `src/top.sv` | Top-level: wires all subsystems, Pong physics FSM, font ROM, pixel compositing |
| `src/cpu.sv` | Custom 16-bit RISC CPU — 8 registers, 16 opcodes, direct + indirect addressing |
| `src/alu.sv` | 8-operation ALU (ADD/SUB/AND/OR/XOR/MOV/SHL/SHR) |
| `src/regfile.sv` | 8×16-bit register file |
| `src/mmio.sv` | Memory-mapped I/O — paddle, ball position, game state, buttons, sprite table |
| `src/gpu.sv` | 32-sprite engine, 8×8 tiles, 8 tile patterns, 8-color palette, hardware collision |
| `src/vga_timing.sv` | 640×480 @ 60 Hz VGA timing generator |
| `src/instr_rom.sv` | Dual-mode: BRAM simulation path or W25Q32 SPI NOR Flash cartridge |

### MMIO Map

| Address | Name | Direction | Description |
|---|---|---|---|
| `0x00` | `PADDLE_Y` | R/W | Player paddle Y (0–400) |
| `0x01` | `BALL_X` | R | Ball X (hardware) |
| `0x02` | `BALL_Y` | R | Ball Y (hardware) |
| `0x03` | `GAME_STATE` | R/W | 0=TITLE 1=PLAY 2=GAMEOVER 3=PAUSE |
| `0x04` | `SCORE` | R/W | `[15:8]`=right `[7:0]`=left |
| `0x06` | `COL_HIT_LO` | R | Collision bits for sprites 1–15 |
| `0x07` | `COL_HIT_HI` | R | Collision bits for sprites 16–31 |
| `0x10` | `BUTTONS` | R | `[4]`=start `[1]`=down `[0]`=up |
| `0x40–0x7F` | `SPR_X/Y[i]` | R/W | Sprite table (X at even, Y+tile+color at odd) |

## Assembler

The firmware is written in a custom assembly language and assembled with the included Python assembler:

```
cd assembler/
python assemble.py game.asm           # outputs game.mem + game.bin
python assemble.py game.asm -v        # with listing
```

- `game.mem` — loaded via `$readmemh` for simulation (BRAM path)
- `game.bin` — 512-byte big-endian image for programming the W25Q32 flash cartridge

## Hardware Setup

**Board:** Digilent Basys 3 (Artix-7 XC7A35T)

**Peripherals:**
- VGA monitor via onboard VGA connector
- SPI cartridge (W25Q32 DIP-8 NOR Flash) on PMOD JA
- NES-style controller on PMOD JC (active-low)
- Onboard buttons: `btnU`/`btnD` (paddle), `btnC` (reset)

**Cartridge wiring (PMOD JA):**

| W25Q32 Pin | Signal | PMOD JA |
|---|---|---|
| 1 (/CS) | `spi_cs_n` | JA1 |
| 6 (CLK) | `spi_clk` | JA2 |
| 5 (DI) | `spi_mosi` | JA3 |
| 2 (DO) | `spi_miso` | JA4 |
| 7 (/HOLD), 3 (/WP) | — | tie to 3.3V |

## Building

1. Open Vivado, create a new project targeting `xc7a35tcpg236-1`
2. Add all files in `src/` as design sources
3. Add `constraints/constraints.xdc` as a constraint file
4. Set `instr_rom` parameter: `SIMULATION=1` for simulation, `SIMULATION=0` for hardware with cartridge
5. Run synthesis → implementation → generate bitstream

## Game Controls

| Input | Action |
|---|---|
| `btnU` / controller Up | Move paddle up |
| `btnD` / controller Down | Move paddle down |
| Controller A | Start game / pause |
| `btnC` / controller Start | Reset |

First player to 5 points wins.
