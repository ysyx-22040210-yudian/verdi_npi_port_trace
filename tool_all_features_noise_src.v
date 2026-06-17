module TAFNoiseSrc (
  output [6:0] b,
  output [2:0] d,
  output reg n
);
  assign b = 7'h35;
  assign d = 3'h6;

  initial begin
    n = 1'b1;
  end
endmodule
