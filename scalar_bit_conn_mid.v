module ScalarBitConnMid (
  input wire clk
);
  wire        key7;
  wire [31:0] bus;
  wire [31:0] pass0;
  wire [31:0] pass1;

  ScalarBitConnKeySrc u_key7(.clk(clk), .out(key7));

  assign bus[6:0]  = 7'b1010101;
  assign bus[7]    = key7;
  assign bus[15:8] = 8'hA5;
  assign bus[31:16] = 16'h5A5A;
  assign pass0 = bus;
  assign pass1 = pass0;

  ScalarBitConnChild u_child (
    .a(pass1[7]),
    .m0(pass1[7]),
    .m1(pass1[8])
  );
endmodule
