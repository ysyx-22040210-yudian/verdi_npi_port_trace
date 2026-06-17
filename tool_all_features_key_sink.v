module TAFKeySink #(parameter W = 1) (
  input [W-1:0] in,
  output used
);
  assign used = ^in;
endmodule
