module LoaderPressureTop;
  wire [31:0] A;

  LPLoadTarget u_target(
    .a(A)
  );

  LPRootWrap u_root(
    .root_in(A)
  );
endmodule
