module SFPDriverWrap1 (
  input in,
  output out
);
  wire net;
  wire bridge;

  assign bridge = in;

  SFPDriverWrap0 u_wrap0(
    .in(bridge),
    .out(net)
  );

  assign out = net;
endmodule
