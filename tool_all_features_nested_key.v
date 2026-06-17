module TAFNestedKey #(parameter W = 1, parameter VALUE = 1) (
  output [W-1:0] out
);
  TAFKeySrc #(.W(W), .VALUE(VALUE)) u_key_nested(
    .out(out)
  );
endmodule
