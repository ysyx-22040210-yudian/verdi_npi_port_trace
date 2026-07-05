module ScalarBitConnMid (
  input wire clk
);
  wire        key7;
  wire        key8;
  wire [31:0] bus;
  wire [31:0] pass0;
  wire [31:0] pass1;
  wire        alias_a;
  wire        alias_m0;

  ScalarBitConnKeySrc u_key7(.clk(clk), .out(key7));
  ScalarBitConnKeySrc u_key8(.clk(clk), .out(key8));

  assign bus[6:0]  = 7'b1010101;
  assign bus[7]    = key7;
  assign bus[8]    = key8;
  assign bus[15:9] = 7'b0101010;
  assign bus[31:16] = 16'h5A5A;
  assign pass0 = bus;
  assign pass1 = pass0;
  assign alias_a = pass1[7];
  assign alias_m0 = alias_a;

  ScalarBitConnChild u_child (
    .a(alias_a),
    .m0(alias_m0),
    .m1(pass1[8])
  );
endmodule
