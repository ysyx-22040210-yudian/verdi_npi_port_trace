`define TAF_UNKNOWN_DIR_INPUT input

module TAFUnknownDirProbe(a);
  `TAF_UNKNOWN_DIR_INPUT [20:0] a;

  wire used;
  assign used = ^a;
endmodule
