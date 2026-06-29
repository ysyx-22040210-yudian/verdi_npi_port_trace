module BPStressChild (
  input  wire [7:0] A,
  input  wire       one_bit_from_bus,
  input  wire       ternary_stop,
  output wire [20:0] Y
);
  assign Y = A[7] ? 21'h155555 : 21'h0aaaaa;
endmodule
