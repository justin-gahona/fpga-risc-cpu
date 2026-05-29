#!/usr/bin/env python3
"""
assemble.py — Two-pass assembler for the Basys_retro custom CPU
================================================================
Usage:
    python assemble.py game.asm              # outputs game.mem
    python assemble.py game.asm out.mem      # custom output name
    python assemble.py game.asm -v           # verbose listing

ISA Summary (16-bit instruction word):
---------------------------------------
R-type  (opcodes 0x0–0x7):   {op[3:0], rd[2:0], 1, 00, rs[2:0], 000}
I-type  (opcodes 0x8–0xF):   {op[3:0], rd[2:0], inst[8], imm8[7:0]}
    inst[8]=0 → direct address (imm8)
    inst[8]=1 → indirect address (register rs = inst[5:3])

Opcodes:
  R-type:  ADD SUB AND OR XOR MOV SHL SHR
  I-type:  LD LDI JMP BZ BNZ ANDI ADDI ST
  Aliases: LDR (indirect LD), STR (indirect ST), NOP

Syntax:
  label:          ; define a label at current PC
  ADD  rd, rs     ; R-type register op
  LDI  rd, imm    ; load immediate (8-bit, 0–255)
  ADDI rd, imm    ; add signed immediate (-128 to +127)
  ANDI rd, imm    ; AND with 8-bit immediate
  LD   rd, [addr] ; load from MMIO address (direct)
  LD   rd, [rs]   ; load from MMIO address in rs (indirect)
  LDR  rd, [rs]   ; same as LD indirect (explicit alias)
  ST   rd, [addr] ; store to MMIO address (direct)
  ST   rd, [rs]   ; store to MMIO address in rs (indirect)
  STR  rd, [rs]   ; same as ST indirect (explicit alias)
  JMP  addr       ; unconditional jump
  BZ   rd, addr   ; branch if rd == 0
  BNZ  rd, addr   ; branch if rd != 0
  NOP             ; no operation

Address/immediate: decimal, 0xHEX, or label name
Registers: r0–r7  (case-insensitive: R0, r0, etc.)
Comments: ; or //

MMIO quick reference:
  0x00 = PADDLE_Y          0x10 = BUTTONS
  0x01 = BALL_X (read)     0x40+i*2 = SPR_X[i]
  0x02 = BALL_Y (read)     0x41+i*2 = SPR_Y[i]  (see below)
  0x03 = GAME_STATE        SPR_Y encoding: [15:13]=tile [12:10]=color [8:0]=Y
  0x04 = SCORE             BUTTONS: [1]=btnD [0]=btnU [2]=A [3]=B [4]=start

Tile indices (GPU):  0=solid 1=outline 2=X 3=plus 4=diamond
                     5=smiley 6=heart 7=star
Color indices (GPU): 0=white 1=red 2=green 3=blue
                     4=yellow 5=magenta 6=cyan 7=orange
================================================================
"""

import sys
import re

# --------------- Opcode table ---------------
OPCODES = {
    # mnemonic : (opcode, format)
    'ADD':  (0x0, 'R'),
    'SUB':  (0x1, 'R'),
    'AND':  (0x2, 'R'),
    'OR':   (0x3, 'R'),
    'XOR':  (0x4, 'R'),
    'MOV':  (0x5, 'R'),
    'SHL':  (0x6, 'R'),
    'SHR':  (0x7, 'R'),
    'LD':   (0x8, 'MEM'),   # direct or indirect based on operand
    'LDI':  (0x9, 'RI'),    # rd, imm8
    'JMP':  (0xA, 'J'),     # imm8 only
    'BZ':   (0xB, 'BI'),    # rd, imm8
    'BNZ':  (0xC, 'BI'),    # rd, imm8
    'ANDI': (0xD, 'RI'),
    'ADDI': (0xE, 'RI'),    # signed imm8
    'ST':   (0xF, 'MEM'),   # direct or indirect
    'LDR':  (0x8, 'IND'),   # forced indirect LD
    'STR':  (0xF, 'IND'),   # forced indirect ST
    'NOP':  (0x0, 'NOP'),
}


def err(msg, lineno=None):
    loc = f" (line {lineno})" if lineno else ""
    print(f"ERROR{loc}: {msg}", file=sys.stderr)
    sys.exit(1)


def parse_reg(s, lineno=None):
    s = s.strip().lower()
    if re.fullmatch(r'r[0-7]', s):
        return int(s[1])
    err(f"Expected register r0–r7, got '{s}'", lineno)


def parse_imm(s, labels, lineno=None):
    s = s.strip()
    if s in labels:
        v = labels[s]
    elif s.startswith('0x') or s.startswith('0X'):
        v = int(s, 16)
    elif s.startswith('-'):
        v = int(s, 0)
    else:
        v = int(s, 0)
    return v


def split_operands(s):
    """Split operand string on commas outside brackets."""
    parts, depth, cur = [], 0, ''
    for ch in s:
        if ch == '[':
            depth += 1
        elif ch == ']':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur.strip())
            cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())
    return parts


def parse_mem_operand(s, labels, lineno=None):
    """Parse [imm] or [rs]. Returns (indirect:bool, value:int)."""
    s = s.strip()
    if not (s.startswith('[') and s.endswith(']')):
        err(f"Expected [addr] or [reg], got '{s}'", lineno)
    inner = s[1:-1].strip()
    if re.fullmatch(r'[rR][0-7]', inner):
        return True, parse_reg(inner, lineno)
    return False, parse_imm(inner, labels, lineno)


def encode_instruction(mnem, ops, labels, pc, lineno):
    mnem = mnem.upper()
    if mnem not in OPCODES:
        err(f"Unknown mnemonic '{mnem}'", lineno)

    opcode, fmt = OPCODES[mnem]

    if fmt == 'NOP':
        return 0x0100   # ADD r0, r0 (no side effect)

    if fmt == 'R':
        if len(ops) != 2:
            err(f"{mnem} needs 2 register operands", lineno)
        rd = parse_reg(ops[0], lineno)
        rs = parse_reg(ops[1], lineno)
        return (opcode << 12) | (rd << 9) | (1 << 8) | (rs << 3)

    if fmt == 'RI':
        if len(ops) != 2:
            err(f"{mnem} needs rd and immediate", lineno)
        rd  = parse_reg(ops[0], lineno)
        imm = parse_imm(ops[1], labels, lineno)
        if mnem == 'ADDI':
            if not (-128 <= imm <= 127):
                err(f"ADDI immediate {imm} out of signed 8-bit range", lineno)
            imm &= 0xFF     # two's complement
        else:
            if not (0 <= imm <= 255):
                err(f"{mnem} immediate {imm} out of 8-bit range", lineno)
        return (opcode << 12) | (rd << 9) | (imm & 0xFF)

    if fmt == 'J':
        if len(ops) != 1:
            err(f"JMP needs one address operand", lineno)
        addr = parse_imm(ops[0], labels, lineno) & 0xFF
        return (opcode << 12) | addr

    if fmt == 'BI':
        if len(ops) != 2:
            err(f"{mnem} needs rd and address", lineno)
        rd   = parse_reg(ops[0], lineno)
        addr = parse_imm(ops[1], labels, lineno) & 0xFF
        return (opcode << 12) | (rd << 9) | addr

    if fmt == 'MEM':
        # LD rd, [imm]  or  LD rd, [rs]  (auto-detect)
        if len(ops) != 2:
            err(f"{mnem} needs rd and [addr]", lineno)
        rd = parse_reg(ops[0], lineno)
        indirect, val = parse_mem_operand(ops[1], labels, lineno)
        if indirect:
            rs = val
            return (opcode << 12) | (rd << 9) | (1 << 8) | (rs << 3)
        else:
            if not (0 <= val <= 255):
                err(f"{mnem} address {val} out of 8-bit range", lineno)
            return (opcode << 12) | (rd << 9) | (val & 0xFF)

    if fmt == 'IND':
        # LDR rd, [rs]  or  STR rd, [rs]  — always indirect
        if len(ops) != 2:
            err(f"{mnem} needs rd and [rs]", lineno)
        rd = parse_reg(ops[0], lineno)
        _, rs = parse_mem_operand(ops[1], labels, lineno)
        return (opcode << 12) | (rd << 9) | (1 << 8) | (rs << 3)

    err(f"Internal: unhandled format '{fmt}'", lineno)


def assemble(src):
    lines = src.splitlines()

    # Strip comments and blank lines; keep (lineno, text)
    raw = []
    for i, line in enumerate(lines, 1):
        line = re.sub(r'(//|;).*', '', line).strip()
        if line:
            raw.append((i, line))

    # Pass 1: collect labels and count instructions
    labels = {}
    pc = 0
    for lineno, line in raw:
        if line.endswith(':'):
            name = line[:-1].strip()
            if name in labels:
                err(f"Duplicate label '{name}'", lineno)
            labels[name] = pc
        else:
            pc += 1

    if pc > 256:
        print(f"WARNING: program is {pc} instructions — exceeds 256-word ROM!", file=sys.stderr)

    # Pass 2: encode
    words   = []
    listing = []
    pc = 0

    for lineno, line in raw:
        if line.endswith(':'):
            listing.append(f"           {line}")
            continue

        # Split mnemonic from operands
        m = re.match(r'(\w+)\s*(.*)', line)
        if not m:
            err(f"Cannot parse line: '{line}'", lineno)
        mnem = m.group(1)
        ops  = split_operands(m.group(2)) if m.group(2).strip() else []

        word = encode_instruction(mnem, ops, labels, pc, lineno)
        words.append(word)
        listing.append(f"  0x{pc:02X}: {word:04X}    {line}")
        pc += 1

    return words, listing


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(0)

    asm_file = sys.argv[1]
    verbose  = '-v' in sys.argv
    out_args = [a for a in sys.argv[2:] if not a.startswith('-')]
    mem_file = out_args[0] if out_args else asm_file.rsplit('.', 1)[0] + '.mem'

    with open(asm_file) as f:
        src = f.read()

    words, listing = assemble(src)

    if verbose:
        print(f"=== Listing: {asm_file} ===")
        for line in listing:
            print(line)
        print()

    bin_file = mem_file.rsplit('.', 1)[0] + '.bin'
    print(f"Assembled {len(words)} instructions → {mem_file}, {bin_file}")

    with open(mem_file, 'w') as f:
        f.write(f"// Auto-generated by assemble.py from {asm_file}\n")
        for w in words:
            f.write(f"{w:04X}\n")

    # Big-endian binary for ROM programmer: high byte at 2*PC, low byte at 2*PC+1
    rom_bytes = bytearray()
    for w in words:
        rom_bytes.append((w >> 8) & 0xFF)
        rom_bytes.append(w & 0xFF)
    # Pad to 512 bytes (256-word ROM, 0xFF fill matches erased ROM state)
    rom_bytes += b'\xFF' * (512 - len(rom_bytes))
    with open(bin_file, 'wb') as f:
        f.write(rom_bytes)


if __name__ == '__main__':
    main()
