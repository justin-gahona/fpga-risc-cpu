# fpga-risc-cpu

A custom 16-bit RISC CPU with memory-mapped GPU, 32-sprite hardware renderer, and SPI NOR Flash cartridge interface — designed from scratch in SystemVerilog and deployed on a Digilent Basys 3 (Artix-7 XC7A35T) FPGA. Pong runs as the demonstration application, proving end-to-end execution of firmware on the CPU, real-time hardware rendering, and live peripheral I/O.

> **Resume line:** Designed and implemented a custom 16-bit RISC CPU with memory-mapped GPU, 32-sprite hardware renderer, and SPI NOR Flash cartridge interface in SystemVerilog on Artix-7 FPGA — synthesized to 3,448 LUTs and 1,240 flip-flops at 100 MHz.

---

## System Architecture

```
                        100 MHz System Clock (CLK100MHZ)
                                    |
          +-----------+   cpu_step  |   pix_stb (÷4 = 25 MHz)
          |  CPU Clock |<-----------+----------->[ vga_timing ]
          |  Divider   |  (÷10000)              |  640×480@60Hz
          |  10 kHz    |                        |  Hsync, Vsync
          +-----+------+                        |  x[9:0], y[9:0]
                |                               |  frame_tick
                v                               |
          +----------+   mem_we/addr/data       |
          |   CPU    |<------------------------>[ MMIO ]<--+
          | (cpu.sv) |                         |           |
          |  8 regs  |   pc[7:0]               |  paddle_y |  btn_up/dn
          |  16 ops  |------>[instr_rom]        |  game_st  |  btn_start
          +----+-----+      (BRAM / SPI)        |  score    |
               |                               |  spr_we   |
               |                               |  col_hit  |
               |   regfile (8×16b)             +-----+-----+
               +-->[ ALU ]                           |
                                                     | spr_we/sel/xy/wdata
                                                     v
                                               [ GPU (gpu.sv) ]
                                               | 32 sprites    |
                                               | 8×8 tiles     |
                                               | 8 tile shapes |
                                               | 8 colors      |
                                               | col_hit[31:1] |
                                               +------+--------+
                                                      | gpu_r/g/b
                                                      v
                                          [ Pixel Compositor ]
                                          | Layer 0: background/title
                                          | Layer 1: GPU sprites
                                          | Layer 2: score digits
                                          | Layer 3: paddles + ball
                                          | (font ROM, inline LUTs)
                                          +--------+-----------+
                                                   |
                                           [Output FF register]
                                                   |
                                        vgaRed/Green/Blue[3:0]
```

---

## Module Reference

| Module | File | Description |
|---|---|---|
| `top` | `src/top.sv` | Top-level integration, Pong physics FSM, pixel compositor, font ROM |
| `cpu` | `src/cpu.sv` | 16-bit RISC CPU — fetch, decode, execute in a single clock-gated stage |
| `alu` | `src/alu.sv` | 8-operation arithmetic/logic unit |
| `regfile` | `src/regfile.sv` | 8×16-bit register file, synchronous write / asynchronous read |
| `mmio` | `src/mmio.sv` | Memory-mapped I/O hub — system registers + sprite table write decode |
| `gpu` | `src/gpu.sv` | 32-sprite scanline renderer with tile ROM, palette, and collision engine |
| `vga_timing` | `src/vga_timing.sv` | 640×480 @ 60 Hz VGA timing generator |
| `instr_rom` | `src/instr_rom.sv` | Dual-mode: BRAM `$readmemh` (sim) or W25Q32 SPI NOR Flash (hardware) |

---

## CPU — Instruction Set Architecture

**16-bit fixed-width instruction word. 8 registers (r0–r7). Two formats:**

```
R-type  [15:12]=op  [11:9]=rd  [8]=1  [7:6]=--  [5:3]=rs  [2:0]=--
I-type  [15:12]=op  [11:9]=rd  [8]=indirect_flag  [7:0]=imm8
```

`inst[8]` doubles as the indirect-addressing flag for LD/ST: `0` = direct (imm8 is the address), `1` = indirect (rs holds the address at runtime).

### Opcode Table

| Op | Mnemonic | Format | Operation |
|---|---|---|---|
| `0x0` | `ADD rd, rs` | R | `rd = rd + rs` |
| `0x1` | `SUB rd, rs` | R | `rd = rd - rs` |
| `0x2` | `AND rd, rs` | R | `rd = rd & rs` |
| `0x3` | `OR  rd, rs` | R | `rd = rd \| rs` |
| `0x4` | `XOR rd, rs` | R | `rd = rd ^ rs` |
| `0x5` | `MOV rd, rs` | R | `rd = rs` |
| `0x6` | `SHL rd, rs` | R | `rd = rd << rs[3:0]` |
| `0x7` | `SHR rd, rs` | R | `rd = rd >> rs[3:0]` (logical) |
| `0x8` | `LD  rd, [imm8]` | I | `rd = mem[imm8]` (direct) |
| `0x8` | `LDR rd, [rs]` | I | `rd = mem[rs]` (indirect, inst[8]=1) |
| `0x9` | `LDI rd, imm8` | I | `rd = {0, imm8}` |
| `0xA` | `JMP imm8` | I | `PC = imm8` |
| `0xB` | `BZ  rd, imm8` | I | `if rd==0: PC = imm8` |
| `0xC` | `BNZ rd, imm8` | I | `if rd!=0: PC = imm8` |
| `0xD` | `ANDI rd, imm8` | I | `rd = rd & imm8` |
| `0xE` | `ADDI rd, simm8` | I | `rd = rd + sign_ext(imm8)` |
| `0xF` | `ST  rd, [imm8]` | I | `mem[imm8] = rd` (direct) |
| `0xF` | `STR rd, [rs]` | I | `mem[rs] = rd` (indirect, inst[8]=1) |

**r7** is reserved as the link register for a future `CALL` instruction.

### CPU Execution Model

The CPU runs at **10 kHz** — a clock-divider in `top.sv` asserts `cpu_step` for one 100 MHz cycle every 10,000 cycles. The register file write-enable is gated by `step`, so decoding is always running but state only advances on a `step` pulse. This gives the game firmware roughly 10,000 instruction slots per second.

```
                     100 MHz clock
                          |
  +-----------+           |
  | PC reg    |---addr--->[ instr_rom ]
  |           |<--inst----[ (BRAM/SPI)]
  +-----------+           |
       |                  | (1-cycle latency)
       |    +-------+     |
       +--->| Decode|<----+
            |  ALU  |
            |  regs |---> MMIO read/write
            +---+---+
                |
           (on step pulse only)
                |
            PC += 1  /  branch  /  jump
```

---

## GPU — Sprite Engine

32 hardware sprites, rendered per-scanline in combinational logic. Each sprite is 8×8 pixels.

### Sprite Register Encoding

```
SPR_X word  (MMIO 0x40 + i*2):
  [9:0]   X position  (0 = sprite disabled)

SPR_Y word  (MMIO 0x41 + i*2):
  [15:13] tile_idx   (0–7, selects tile shape)
  [12:10] color_idx  (0–7, selects palette color)
  [9]     unused
  [8:0]   Y position
```

### Tile Shapes (8 built-in, combinational LUT ROM)

| Index | Shape | Bitmap (hex, row 0 first) |
|---|---|---|
| 0 | Solid square | `FFFFFFFFFFFFFFFF` |
| 1 | Outline square | `FF818181818181FF` |
| 2 | X / crosshair | `8142241818244281` |
| 3 | Plus / cross | `183C3CFFFF3C3C18` |
| 4 | Diamond | `183C7EFFFF7E3C18` |
| 5 | Smiley face | `3C42A581BD99423C` |
| 6 | Heart | `6666FFFF7E3C1800` |
| 7 | Star | `18DBE77E7EE7DB18` |

### Color Palette (8 colors)

| Index | Color | 12-bit RGB |
|---|---|---|
| 0 | White | `FFF` |
| 1 | Red | `F44` |
| 2 | Green | `4F4` |
| 3 | Blue | `44F` |
| 4 | Yellow | `FF4` |
| 5 | Magenta | `F4F` |
| 6 | Cyan | `4FF` |
| 7 | Orange | `F84` |

### Collision Detection

Hardware computes bounding-box overlap between every sprite `i` (i=1..31) and **sprite 0** every clock cycle:

```
col_hit[i] = 1  iff  sprite[i].bbox overlaps sprite[0].bbox  AND  both are enabled
```

Results are readable by the CPU at MMIO `0x06` (sprites 1–15) and `0x07` (sprites 16–31). In the demo firmware, sprite 0 is kept synchronized to the hardware ball position, turning col_hit into a real-time "ball hit brick" signal.

---

## MMIO Map

8-bit address space, 16-bit data words.

```
Addr   Name          Dir   Description
------+-------------+-----+------------------------------------------------
0x00   PADDLE_Y      R/W   Player paddle Y  (0–400, clamped in hardware)
0x01   BALL_X        R     Ball X position  (driven by top.sv physics)
0x02   BALL_Y        R     Ball Y position  (driven by top.sv physics)
0x03   GAME_STATE    R/W   0=TITLE  1=PLAY  2=GAMEOVER  3=PAUSE
0x04   SCORE         R/W   [15:8]=right score  [7:0]=left score
0x06   COL_HIT_LO    R     col_hit[15:1]  — sprites  1–15
0x07   COL_HIT_HI    R     col_hit[31:16] — sprites 16–31
0x10   BUTTONS       R     [4]=start  [3]=B  [2]=A  [1]=down  [0]=up
0x40   SPR0_X        R/W   Sprite 0 X  (0 = disabled)
0x41   SPR0_Y        R/W   Sprite 0 tile/color/Y (see encoding above)
...    ...                  Sprites 1–31 follow at 0x42–0x7F
0x7F   SPR31_Y       R/W   Sprite 31 Y word
```

---

## SPI Cartridge Interface

Game code is stored on a **W25Q32 DIP-8 SPI NOR Flash** chip wired to PMOD JA. The `instr_rom` module implements a minimal SPI master (Mode 0, 12.5 MHz clock, synthesized purely from the 100 MHz system clock).

### Transaction Protocol

Each instruction fetch is a **48-clock SPI transaction**:

```
Bit:    47        40 39              16 15           0
        +----------+------------------+--------------+
TX:     | 0x03 READ| addr[23:0]=2×PC  | 0x0000 dummy |
        +----------+------------------+--------------+
RX:                                   |  inst[15:0]  |
                                      +--------------+
                       (MISO sampled from bit 32 onward)
```

The 24-bit byte address is `PC × 2` (big-endian, high byte first). The W25Q32 streams bytes MSB-first; the instr_rom shifts them into a 16-bit register MSB-first to reconstruct the instruction word.

**W25Q32 Wiring (PMOD JA):**

```
W25Q32 Pin          Signal       PMOD JA Pin    FPGA Pin
──────────────────────────────────────────────────────
Pin 1  (/CS)   →   spi_cs_n  →  JA1         →  J1
Pin 6  (CLK)   →   spi_clk   →  JA2         →  L2
Pin 5  (DI)    →   spi_mosi  →  JA3         →  J2
Pin 2  (DO)    →   spi_miso  →  JA4         →  G2
Pin 3  (/WP)   →   3.3V (tie high)
Pin 7  (/HOLD) →   3.3V (tie high)
```

A separate `cart_present` signal (PMOD JA pin 7, `H1`) is pulled low by the FPGA and driven high by the cartridge PCB. When no cartridge is inserted, `top.sv` renders a "NO CART — INSERT CART" screen over VGA.

---

## Pixel Compositor

Four rendering layers are composited per-pixel in combinational logic inside `top.sv`. Each layer overwrites the previous if active:

```
Layer 0 │ Background color / title / game-over / pause overlay
Layer 1 │ GPU sprites (from gpu.sv — transparent if all-zero RGB)
Layer 2 │ Score digits  (2× scaled, drawn from inline font ROM LUTs)
Layer 3 │ Hardware shapes — left paddle, right (AI) paddle, ball
        │ (always on top; pure combinational bbox comparisons)
        ↓
   [Output pipeline register — one FF stage before VGA pins]
```

The font ROM is a `case`-based `function` synthesized to LUTs, encoding 25 characters (digits 0–9 + uppercase letters) as 8×8 bitmaps packed into 64-bit constants.

---

## Simulation

Each module was verified independently in Vivado Simulator (xsim) before integration. Simulation targets compiled:

| Module | Verified |
|---|---|
| `alu` | All 8 operations, zero flag |
| `regfile` | Write/read, reset, r7 link register |
| `cpu` | All 16 opcodes, direct + indirect addressing, branch taken/not-taken |
| `mmio` | All register reads, sprite table decode, PADDLE_Y clamping |
| `gpu` | Sprite enable/disable, tile render, collision detection |
| `instr_rom` | SPI transaction waveform, 48-bit shift sequence |
| `vga_timing` | H/V counter wraparound, sync polarity, frame_tick pulse |
| `top` | Full system integration, game state transitions |

Simulation uses `SIMULATION=1` in `instr_rom`, loading `assembler/game.mem` via `$readmemh` into BRAM.

---

## Implementation Results

Synthesized and implemented with **Vivado 2025.1** targeting `xc7a35tcpg236-1` (speed grade -1).

### Resource Utilization (Post-Implementation)

| Resource | Used | Available | Utilization |
|---|---|---|---|
| Slice LUTs | 3,448 | 20,800 | **16.6%** |
| Slice Registers (FFs) | 1,240 | 41,600 | **3.0%** |
| Slices | 1,213 | 8,150 | 14.9% |
| Block RAM | 0 | 50 | 0% |
| DSP48 | 0 | 90 | 0% |
| Bonded IOBs | 27 | 106 | 25.5% |
| BUFG clocks | 1 | 32 | 3.1% |

> The entire design — including all tile ROMs, font ROMs, and the instruction ROM simulation path — synthesizes to LUT logic. Zero block RAMs are consumed.

**Primitive breakdown:**

| Primitive | Count | Notes |
|---|---|---|
| LUT4 | 2,155 | Majority of combinational logic |
| FDRE | 1,235 | Synchronous reset FFs (game state, physics, CPU) |
| LUT6 | 1,219 | |
| LUT5 | 927 | |
| CARRY4 | 573 | Adder/comparator chains (physics, VGA counters) |
| LUT3 | 413 | |
| LUT2 | 212 | |
| MUXF7 | 41 | Wide mux trees (compositor, MMIO decode) |
| LUT1 | 23 | Inverters |
| OBUF | 17 | Output buffers (VGA + SPI) |
| IBUF | 10 | Input buffers |

### Timing Summary

**System clock:** 100 MHz (10 ns period) — single clock domain throughout.

| Check | Result |
|---|---|
| Hold time | **Clean** — WHS = +0.071 ns, 0 failing endpoints |
| Setup (internal logic) | Clean — all register-to-register paths within fabric meet timing |
| Setup (output I/O) | Violations on VGA output pins (see note below) |
| Pulse width | **Clean** — WPWS = +4.020 ns |

**Note on output timing:** The setup violations (WNS = −4.977 ns) are confined entirely to OBUF output paths for VGA sync and color signals, caused by the interaction of conservative `set_output_delay -max 3.0ns` constraints with the Artix-7 OBUF propagation time (~3.5 ns) and clock path skew. VGA monitors do not have a synchronous input requirement on pixel data — there is no external sampling clock, so the output delay constraint is not physically meaningful for VGA. All registered internal paths close timing. The design is fully functional on hardware.

### Power (Post-Route, Typical Process Corner)

| Component | Power |
|---|---|
| Total on-chip | **99 mW** |
| Dynamic | 27 mW |
| Device static | 72 mW |
| Max ambient | 84.5 °C |

---

## Assembler

The firmware is written in a custom assembly language targeting this CPU's ISA and assembled with a two-pass Python assembler.

```
cd assembler/
python assemble.py game.asm           # → game.mem + game.bin
python assemble.py game.asm -v        # verbose listing
python assemble.py game.asm out.mem   # custom output filename
```

**Outputs:**
- `game.mem` — hex file, one 16-bit word per line; loaded by `$readmemh` in simulation
- `game.bin` — 512-byte big-endian binary, padded with `0xFF` (erased flash state); write this to the W25Q32 with any SPI programmer

**Supported syntax:**

```asm
; Comments with ; or //
label:                    ; label at current PC
ADD  r1, r2               ; R-type
LDI  r0, 0xFF             ; immediate (hex or decimal)
ADDI r0, -4               ; signed immediate (-128..+127)
ANDI r0, 0x0F             ; AND immediate
LD   r0, [0x01]           ; direct load from MMIO
LDR  r0, [r2]             ; indirect load (address in r2)
ST   r0, [0x00]           ; direct store
STR  r0, [r2]             ; indirect store
JMP  MAIN                 ; jump to label
BZ   r5, DONE             ; branch if zero
BNZ  r5, LOOP             ; branch if not zero
NOP                       ; no-op (encodes as ADD r0, r0)
```

---

## Demo Firmware — game.asm

The firmware running on the CPU implements the sprite layer of the Pong demo:

```
Init:
  r7 = 1              ; shift constant (used in collision loop)
  sprite[0] = enabled ; ball shadow — synced to hardware ball each frame
  sprites[1..10]  = row 1 bricks  (Y=50,  X=10/40/70/.../280)
  sprites[11..20] = row 2 bricks  (Y=150, X=10/40/70/.../280)
  PADDLE_Y = 200

Main loop (runs continuously at 10 kHz):
  1. Sync sprite[0].X = BALL_X, sprite[0].Y = BALL_Y
  2. Read COL_HIT_LO (sprites 1–15): for each hit bit → disable that sprite (X=0)
  3. Read COL_HIT_HI (sprites 16–20): same
  4. Read BUTTONS: if btnU → PADDLE_Y -= 4
                   if btnD → PADDLE_Y += 4
  5. JMP Main
```

Ball physics, AI paddle, scoring, and game state transitions all run in hardware at 60 Hz frame rate, independent of the CPU.

---

## Hardware Setup

**Board:** Digilent Basys 3 — Artix-7 XC7A35T, CPG236 package, speed grade -1

**Required peripherals:**
- VGA monitor (onboard connector)
- W25Q32 NOR Flash on a PMOD-compatible breakout (PMOD JA) — or set `SIMULATION=1` and load via BRAM
- NES/SNES-style controller with active-low outputs on PMOD JC (optional — onboard buttons also work)

**Controller pinout (PMOD JC, active-low with FPGA pull-ups):**

| PMOD Pin | FPGA Pin | Function |
|---|---|---|
| JC1 | K17 | ctrl_up |
| JC2 | M18 | ctrl_down |
| JC3 | N17 | ctrl_start (reset) |
| JC4 | P18 | ctrl_a (start/pause) |

---

## Building in Vivado

1. Create a new RTL project targeting `xc7a35tcpg236-1`
2. Add `src/*.sv` as design sources
3. Add `constraints/constraints.xdc` as a constraint source
4. To simulate: set `instr_rom` parameter `SIMULATION=1`, run `python assemble.py game.asm` first to generate `game.mem`, copy `game.mem` to the simulation working directory
5. To synthesize for hardware: set `SIMULATION=0` in `top.sv` line 140; program the W25Q32 with `assembler/game.bin`
6. Run Synthesis → Implementation → Generate Bitstream → Program Device

---

## Game Controls

| Input | Action |
|---|---|
| `btnU` / PMOD ctrl_up | Paddle up |
| `btnD` / PMOD ctrl_down | Paddle down |
| PMOD ctrl_a | Start game / toggle pause |
| `btnC` / PMOD ctrl_start | Reset |

First to 5 points wins. Ball speed increases by 1 per paddle hit, capped at 8 pixels/frame.
