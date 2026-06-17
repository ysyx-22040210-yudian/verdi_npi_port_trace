module SFPDecoyConsumer (
  input net,
  input [31:0] bus
);
  wire alias0;
  wire [7:0] alias_slice;
  wire decoy_used;

  assign alias0 = net;
  assign alias_slice = bus[7:0];
  assign decoy_used = alias0 ^ ^alias_slice;
endmodule
