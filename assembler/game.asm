; ================================================================
; game.asm  —  Pong Sprite Engine
; Assemble: python assemble.py game.asm game.mem
;           python assemble.py game.asm -v   (with listing)
; ================================================================
;
; Register map:
;   r0 = scratch / data
;   r1 = button read / scratch
;   r2 = sprite MMIO address (loop pointer)
;   r3 = sprite X accumulator
;   r4 = sprite Y value
;   r5 = loop counter
;   r6 = col_hit word (collision bits)
;   r7 = 1  (shift amount — set once at init, never changed)
;
; MMIO map:
;   0x00  PADDLE_Y     player paddle Y (CPU-written)
;   0x01  BALL_X       ball X (hardware read-only)
;   0x02  BALL_Y       ball Y (hardware read-only)
;   0x06  COL_HIT_LO   col_hit[15:1]  — sprites  1-15
;   0x10  BUTTONS      [1]=btnD  [0]=btnU
;   0x40  SPR0_X       sprite 0 X  (0 = disabled)
;   0x41  SPR0_Y       sprite 0 Y  [15:13]=tile [12:10]=color [8:0]=Y
;   0x42+ sprite table pairs (X then Y)
;
; Sprite 0 = ball shadow — kept in sync with hardware ball for
;            collision detection (col_hit[i] = overlap with spr0).
;            Sprite 0 itself is drawn over by the hardware ball shape.
; Sprites 1-10  = top row   (Y=50,  X=10,40,70,...,280)
; Sprites 11-20 = bottom row(Y=150, X=10,40,70,...,280)
; ================================================================

; ---------------------------------------------------------------
; Init  r7 = 1  (shift constant, kept forever)
; ---------------------------------------------------------------
        LDI  r7, 1

; ---------------------------------------------------------------
; Init sprite 0 (ball shadow — will be synced in main loop)
; ---------------------------------------------------------------
        LDI  r0, 50
        ST   r0, [0x40]         ; SPR0_X = 50 (enables sprite 0)
        LDI  r0, 120
        ST   r0, [0x41]         ; SPR0_Y = 120

; ---------------------------------------------------------------
; Init sprites 1–10: row 1  Y=50, X = 10, 40, 70 ... 280
; ---------------------------------------------------------------
        LDI  r2, 0x42           ; MMIO address of sprite 1 X
        LDI  r3, 10             ; starting X
        LDI  r4, 50             ; Y = 50
        LDI  r5, 10             ; loop count

LOOP1:
        STR  r3, [r2]           ; SPR_X[i] = X
        ADDI r2, 1
        STR  r4, [r2]           ; SPR_Y[i] = Y  (tile=0 solid, color=0 white)
        ADDI r2, 1
        ADDI r3, 30             ; X += 30
        ADDI r5, -1
        BNZ  r5, LOOP1

; ---------------------------------------------------------------
; Init sprites 11–20: row 2  Y=150, X = 10, 40, 70 ... 280
; ---------------------------------------------------------------
        LDI  r3, 10             ; reset X
        LDI  r4, 150            ; Y = 150
        LDI  r5, 10

LOOP2:
        STR  r3, [r2]
        ADDI r2, 1
        STR  r4, [r2]
        ADDI r2, 1
        ADDI r3, 30
        ADDI r5, -1
        BNZ  r5, LOOP2

; ---------------------------------------------------------------
; Init paddle
; ---------------------------------------------------------------
        LDI  r0, 200
        ST   r0, [0x00]         ; PADDLE_Y = 200

; ================================================================
; MAIN GAME LOOP
; ================================================================

MAIN:
        ; ---- Sync sprite 0 to ball position ----
        LD   r0, [0x01]         ; read BALL_X (hardware)
        ST   r0, [0x40]         ; SPR0_X = BALL_X
        LD   r0, [0x02]         ; read BALL_Y (hardware)
        ST   r0, [0x41]         ; SPR0_Y = BALL_Y

        ; ---- Collision loop — disable sprites that hit the ball ----
        ; col_hit[15:1] is at MMIO 0x06.  Bit 0 = sprite 1 status, etc.
        LD   r6, [0x06]         ; r6 = col_hit[15:1]
        LDI  r2, 0x42           ; r2 = SPR1_X MMIO address
        LDI  r5, 15             ; check 15 sprites (1-15)

COL_LOOP:
        MOV  r0, r6             ; r0 = current collision bits
        ANDI r0, 0x01           ; isolate bit 0 (current sprite's hit)
        BZ   r0, NO_HIT         ; not hit → skip disable

        LDI  r0, 0
        STR  r0, [r2]           ; write X=0  → disable this sprite

NO_HIT:
        ADDI r2, 2              ; advance to next sprite X address
        SHR  r6, r7             ; shift col_hit right by 1 (r7=1)
        ADDI r5, -1
        BNZ  r5, COL_LOOP

        ; ---- Collision loop 2 — sprites 16-20 (col_hit[31:16] at 0x07) ----
        ; After COL_LOOP, r2 is already at sprite 16 X addr (0x60)
        LD   r6, [0x07]         ; r6 = col_hit[31:16]
        LDI  r5, 5              ; check 5 sprites (16-20)

COL_LOOP2:
        MOV  r0, r6
        ANDI r0, 0x01
        BZ   r0, NO_HIT2

        LDI  r0, 0
        STR  r0, [r2]           ; write X=0  → disable sprite

NO_HIT2:
        ADDI r2, 2
        SHR  r6, r7
        ADDI r5, -1
        BNZ  r5, COL_LOOP2

        ; ---- Player paddle: btnU moves up ----
        LD   r1, [0x10]         ; read BUTTONS
        ANDI r1, 0x01           ; isolate btnU (bit 0)
        BZ   r1, CHKDN          ; not pressed → check down

        LD   r0, [0x00]         ; read PADDLE_Y
        ADDI r0, -4             ; move up
        ST   r0, [0x00]         ; write PADDLE_Y

CHKDN:
        LD   r1, [0x10]
        ANDI r1, 0x02           ; isolate btnD (bit 1)
        BZ   r1, MAIN           ; not pressed → back to top

        LD   r0, [0x00]
        ADDI r0, 4              ; move down
        ST   r0, [0x00]

        JMP  MAIN
