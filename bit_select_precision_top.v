module BSPTop;
  reg clk;
  wire [7:0] A;
  wire key7;

  initial begin
    clk = 1'b0;
  end

  always #5 clk = ~clk;

  BSPKeySrc u_key7(.clk(clk), .out(key7));

  assign A = {
    key7,
    1'b1,
    1'b0,
    1'b0,
    1'b0,
    1'b0,
    1'b0,
    1'b0
  };

  BSPChild u_child(.A(A));
endmodule
