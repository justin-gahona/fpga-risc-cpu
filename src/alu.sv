`timescale 1ns/1ps
// =============================================================
// alu.sv  —  Arithmetic Logic Unit
// =============================================================
// 3-bit op matches the R-type opcode lower 3 bits (inst[14:12])
// and is also used by the CPU for I-type arithmetic ops.
//
// op | Mnemonic | Operation
// ---|----------|-----------------------------
// 000| ADD      | a + b
// 001| SUB      | a - b
// 010| AND      | a & b
// 011| OR       | a | b
// 100| XOR      | a ^ b
// 101| MOV      | b  (pass-through, used for LDI / LD)
// 110| SHL      | a << b[3:0]  (logical left shift)
// 111| SHR      | a >> b[3:0]  (logical right shift)
// =============================================================

module alu (
  input  logic [2:0]  op,
  input  logic [15:0] a,
  input  logic [15:0] b,
  output logic [15:0] result,
  output logic        zero      // 1 when result == 0
);

  always_comb begin
    case (op)
      3'b000: result = a + b;
      3'b001: result = a - b;
      3'b010: result = a & b;
      3'b011: result = a | b;
      3'b100: result = a ^ b;
      3'b101: result = b;
      3'b110: result = a << b[3:0];
      3'b111: result = a >> b[3:0];
    endcase
  end

  assign zero = (result == 16'd0);

endmodule
