`timescale 1ns / 1ps
// Ethernet CRC32 (FCS), byte-wide update.
//
// Polynomial 0x04C11DB7, initial value 0xFFFFFFFF, final inversion. Ethernet
// sends bits LSB first, so this uses the bit-reversed form of the polynomial
// (0xEDB88320) and shifts right. Then the FCS byte order on the wire is
// fcs[7:0], fcs[15:8], fcs[23:16], fcs[31:24], where fcs = ~crc.
//
// The XOR network for a byte is not hand-derived: the loop below is the
// bit-serial definition, and synthesis unrolls it into one level of logic.
//
// Check: CRC over a whole frame including its FCS leaves crc == 0xDEBB20E3.

package crc32_pkg;

  localparam logic [31:0] CRC32_INIT    = 32'hFFFF_FFFF;
  localparam logic [31:0] CRC32_RESIDUE = 32'hDEBB_20E3;

  function automatic logic [31:0] crc32_byte(input logic [31:0] crc,
                                             input logic [7:0]  data);
    logic [31:0] c;
    c = crc;
    for (int i = 0; i < 8; i++)
      c = (c[0] ^ data[i]) ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
    return c;
  endfunction

endpackage
