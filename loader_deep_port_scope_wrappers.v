module LDPSWrap0 (
  input clk,
  output used
);
  LDPSSubsystem u_sub (
    .clk(clk),
    .used(used)
  );
endmodule

module LDPSWrap1 (
  input clk,
  output used
);
  wire inner_used;

  LDPSWrap0 u_wrap0 (
    .clk(clk),
    .used(inner_used)
  );

  assign used = inner_used;
endmodule

module LDPSWrap2 (
  input clk,
  output used
);
  wire inner_used;

  LDPSWrap1 u_wrap1 (
    .clk(clk),
    .used(inner_used)
  );

  assign used = inner_used;
endmodule

module LDPSWrap3 (
  input clk,
  output used
);
  wire inner_used;

  LDPSWrap2 u_wrap2 (
    .clk(clk),
    .used(inner_used)
  );

  assign used = inner_used;
endmodule

module LDPSCluster (
  input clk,
  output used
);
  wire deep_used;

  LDPSWrap3 u_wrap3 (
    .clk(clk),
    .used(deep_used)
  );

  assign used = deep_used;
endmodule
