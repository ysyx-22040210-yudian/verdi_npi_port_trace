module SourceUnavailableBitDriver #(
  parameter INIT = 1'b0
) (
  output reg out
);
  initial begin
    out = INIT;
  end
endmodule
