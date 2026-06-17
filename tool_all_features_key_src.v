module TAFKeySrc #(parameter W = 1, parameter VALUE = 1) (
  output [W-1:0] out
);
  assign out = VALUE;
endmodule
