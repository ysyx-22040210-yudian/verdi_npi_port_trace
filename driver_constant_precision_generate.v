module DCP_GenerateSource #(
  parameter integer ONE = 1
) (
  output wire out
);
  generate
    if (ONE) begin : g_one
      assign out = 1'b1;
    end else begin : g_zero
      assign out = 1'b0;
    end
  endgenerate
endmodule

module DCP_ParamSource #(
  parameter VALUE = 1'b0
) (
  output wire out
);
  assign out = VALUE;
endmodule

module DCP_ImplicitGenerateSource #(
  parameter ONE = 1'b1
) (
  output wire inactive
);
  if (ONE) begin : g_inactive
    assign inactive = 1'b1;
  end
endmodule
