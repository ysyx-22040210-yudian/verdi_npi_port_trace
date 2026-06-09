module LoaderUnknownDirTarget(
  output [20:0] A
);
  assign A = 21'h13579;
endmodule

module LoaderUnknownDirKeyword #(
  parameter W = 1
) (
  input [W-1:0] in
);
  wire used;
  assign used = ^in;
endmodule

module LoaderUnknownDirTop;
  wire [20:0] A;
  wire [10:0] B;
  wire [9:0] C;

  LoaderUnknownDirTarget u_target(
    .A(A)
  );

  LoaderUnknownDirProbe u_child(
    .a(A)
  );

  assign B = A[10:0];
  assign C = A[20:11];

  LoaderUnknownDirKeyword #(
    .W(11)
  ) u_key_b(
    .in(B)
  );

  LoaderUnknownDirKeyword #(
    .W(10)
  ) u_key_c(
    .in(C)
  );
endmodule

