`timescale 1ns/1ps
// =============================================================
// cpu.sv  —  Custom 16-bit RISC CPU
// =============================================================
//
// ISA — 16-bit instruction word, 8 registers (r0-r7)
//
// Two instruction formats:
//
//   R-type  (opcodes 0x0 – 0x7):
//     [15:12] op4   [11:9] rd   [8:6] ---   [5:3] rs   [2:0] ---
//
//   I-type  (opcodes 0x8 – 0xF):
//     [15:12] op4   [11:9] rd   [8] ---      [7:0] imm8
//
// Opcode table:
//   0x0  ADD  rd, rs       rd = rd + rs
//   0x1  SUB  rd, rs       rd = rd - rs
//   0x2  AND  rd, rs       rd = rd & rs
//   0x3  OR   rd, rs       rd = rd | rs
//   0x4  XOR  rd, rs       rd = rd ^ rs
//   0x5  MOV  rd, rs       rd = rs
//   0x6  SHL  rd, rs       rd = rd << rs[3:0]
//   0x7  SHR  rd, rs       rd = rd >> rs[3:0]  (logical)
//   0x8  LD   rd, [imm8]   rd = mem[imm8]
//   0x9  LDI  rd, imm8     rd = {0, imm8}
//   0xA  JMP  imm8         PC = imm8
//   0xB  BZ   rd, imm8     if rd==0  PC = imm8
//   0xC  BNZ  rd, imm8     if rd!=0  PC = imm8
//   0xD  ANDI rd, imm8     rd = rd & imm8
//   0xE  ADDI rd, simm8    rd = rd + sign_ext(imm8)
//   0xF  ST   rd, [imm8]   mem[imm8] = rd
//
// r7 is the link register for CALL (reserved for future use).
// =============================================================

module cpu (
  input  logic        clk,
  input  logic        rst,
  input  logic        step,      // 1-cycle execute pulse

  output logic [7:0]  pc,        // program counter → instruction ROM

  input  logic [15:0] inst,      // instruction from ROM (registered, 1-cycle latency)

  output logic        mem_we,    // MMIO write strobe
  output logic [7:0]  mem_addr,  // MMIO address
  output logic [15:0] mem_wdata, // MMIO write data
  input  logic [15:0] mem_rdata  // MMIO read data
);

  // ------------------------------------------------------------------
  // Instruction decode
  // ------------------------------------------------------------------
  logic [3:0] op;
  logic [2:0] rd_addr, rs_addr;
  logic [7:0] imm8;

  assign op      = inst[15:12];
  assign rd_addr = inst[11:9];
  assign rs_addr = inst[5:3];
  assign imm8    = inst[7:0];

  // R-type when op[3]==0  (opcodes 0x0 – 0x7)
  wire is_rtype = ~op[3];

  // ------------------------------------------------------------------
  // Register file
  // ------------------------------------------------------------------
  logic        rf_we;
  logic [15:0] rf_wd;
  logic [15:0] rd_data, rs_data;

  regfile u_rf (
    .clk    (clk),
    .rst    (rst),
    .we     (rf_we & step),   // only write on an execute pulse
    .rd_addr(rd_addr),
    .rs_addr(rs_addr),
    .wd     (rf_wd),
    .rd_data(rd_data),
    .rs_data(rs_data)
  );

  // ------------------------------------------------------------------
  // ALU
  // ------------------------------------------------------------------
  logic [2:0]  alu_op;
  logic [15:0] alu_b;
  logic [15:0] alu_result;

  alu u_alu (
    .op    (alu_op),
    .a     (rd_data),
    .b     (alu_b),
    .result(alu_result),
    .zero  ()            // unused here; BZ/BNZ compare rd_data directly
  );

  // ------------------------------------------------------------------
  // Decode: ALU operation + B-operand + regfile write
  // ------------------------------------------------------------------
  always_comb begin
    // Defaults
    alu_op = 3'b000;
    alu_b  = 16'd0;
    rf_we  = 1'b0;
    rf_wd  = alu_result;

    if (is_rtype) begin
      // R-type: lower 3 bits of opcode map directly to ALU op
      alu_op = op[2:0];
      alu_b  = rs_data;
      rf_we  = 1'b1;
    end else begin
      case (op)
        4'h8: begin // LD  rd, [imm8] — load from MMIO
          alu_op = 3'b101;  // MOV
          alu_b  = mem_rdata;
          rf_we  = 1'b1;
        end
        4'h9: begin // LDI rd, imm8 — load zero-extended immediate
          alu_op = 3'b101;  // MOV
          alu_b  = {8'd0, imm8};
          rf_we  = 1'b1;
        end
        4'hD: begin // ANDI rd, imm8 — AND with immediate (zero-extended)
          alu_op = 3'b010;  // AND
          alu_b  = {8'd0, imm8};
          rf_we  = 1'b1;
        end
        4'hE: begin // ADDI rd, simm8 — add sign-extended immediate
          alu_op = 3'b000;  // ADD
          alu_b  = {{8{imm8[7]}}, imm8};
          rf_we  = 1'b1;
        end
        // JMP (0xA), BZ (0xB), BNZ (0xC), ST (0xF): no register write
        default: rf_we = 1'b0;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // Program counter
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      pc <= 8'd0;
    end else if (step) begin
      case (op)
        4'hA:    pc <= imm8;                                         // JMP
        4'hB:    pc <= (rd_data == 16'd0) ? imm8 : pc + 8'd1;       // BZ
        4'hC:    pc <= (rd_data != 16'd0) ? imm8 : pc + 8'd1;       // BNZ
        default: pc <= pc + 8'd1;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // MMIO interface (combinational)
  // ------------------------------------------------------------------
  // inst[8] = 0 → direct  (use imm8 as address)
  // inst[8] = 1 → indirect (use rs_data[7:0] as address, rs = inst[5:3])
  //   Mnemonics: LD/ST (direct) vs LDR/STR (indirect)
  // ------------------------------------------------------------------
  wire [7:0] eff_addr = inst[8] ? rs_data[7:0] : imm8;

  always_comb begin
    mem_we    = 1'b0;
    mem_addr  = 8'd0;
    mem_wdata = 16'd0;

    case (op)
      4'h8: begin                  // LD / LDR
        mem_addr = eff_addr;
      end
      4'hF: begin                  // ST / STR
        mem_we    = step;
        mem_addr  = eff_addr;
        mem_wdata = rd_data;
      end
      default: ;
    endcase
  end

endmodule
