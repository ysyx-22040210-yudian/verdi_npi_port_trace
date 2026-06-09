`define LOADER_UNKNOWN_DIR_INPUT input

module LoaderUnknownDirProbe(a);
  `LOADER_UNKNOWN_DIR_INPUT [20:0] a;

  wire used;
  assign used = ^a;
endmodule

