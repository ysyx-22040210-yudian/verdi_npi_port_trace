module CFAuxTarget #(
  parameter integer MODE = 0
) (
  input aux_in,
  input aux_float,
  output aux_out,
  output aux_unused
);
  assign aux_out = aux_in;
  assign aux_unused = 1'b0;
endmodule
