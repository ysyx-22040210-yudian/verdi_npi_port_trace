module TAFAuxTarget #(parameter MODE = 0) (
  input aux_in,
  input aux_float,
  output aux_out,
  output aux_unused_out
);
  assign aux_out = aux_in;
  assign aux_unused_out = aux_in;
endmodule
