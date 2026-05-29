`timescale 1ns/1ps
// =============================================================
// regfile.sv  —  8 × 16-bit Register File
// =============================================================
// Synchronous write, asynchronous read.
// r0-r6 are general purpose.  r7 is the link register (CALL).
// =============================================================

module regfile (
  input  logic        clk,
  input  logic        rst,
  input  logic        we,        // write enable (qualified with step in cpu)
  input  logic [2:0]  rd_addr,   // destination / read-A address
  input  logic [2:0]  rs_addr,   // source / read-B address
  input  logic [15:0] wd,        // write data
  output logic [15:0] rd_data,   // read port A (rd)
  output logic [15:0] rs_data    // read port B (rs)
);

  logic [15:0] rf [0:7];

  // Synchronous write
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int i = 0; i < 8; i++) rf[i] <= 16'd0;
    end else if (we) begin
      rf[rd_addr] <= wd;
    end
  end

  // Asynchronous read — returns current (pre-write) value
  assign rd_data = rf[rd_addr];
  assign rs_data = rf[rs_addr];

endmodule
