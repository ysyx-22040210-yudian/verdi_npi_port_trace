module LCSDecoyConsumer (
  input net,
  input [20:0] bus,
  output used
);
  wire decoy_net;
  wire [5:0] decoy_slice;

  assign decoy_net = net;
  assign decoy_slice = bus[5:0];
  assign used = decoy_net ^ ^decoy_slice;
endmodule
