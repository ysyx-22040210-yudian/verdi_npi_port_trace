module AssignLoadTarget(
  output [20:0] A
);
  assign A = 21'h155555;
endmodule

module AssignLoadSink #(
  parameter W = 1
) (
  input [W-1:0] in
);
  wire used;
  assign used = ^in;
endmodule

module AssignLoadTop;
  wire [20:0] A;
  wire [10:0] B;
  wire [9:0] C;

  AssignLoadTarget u_target(
    .A(A)
  );

  assign B = A[10:0];
  assign C = A[20:11];

  AssignLoadSink #(
    .W(11)
  ) u_sink_b(
    .in(B)
  );

  AssignLoadSink #(
    .W(10)
  ) u_sink_c(
    .in(C)
  );
endmodule
