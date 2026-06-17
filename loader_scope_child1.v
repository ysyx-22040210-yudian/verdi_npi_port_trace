module LoaderScopeKeySink (
  input in,
  output used
);
  assign used = in;
endmodule

module LoaderScopeChild1 (
  input clk,
  input b,
  output used
);
  reg rb;
  wire sink_used;

  initial begin
    rb = 1'b0;
  end

  always @(posedge clk) begin
    rb <= b;
  end

  LoaderScopeKeySink u_sink(.in(b), .used(sink_used));
  assign used = rb | sink_used;
endmodule
