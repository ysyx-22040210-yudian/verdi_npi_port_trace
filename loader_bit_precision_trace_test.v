module LBPKeySink (
  input wire in
);
  wire used;
  assign used = in;
endmodule

module LBPTarget (
  output wire [10:0] A
);
  assign A = 11'b10101010101;
endmodule

module LBPTop;
  wire [10:0] A;
  wire [10:0] B;

  LBPTarget u_target (
    .A(A)
  );

  assign B = A[10:0];

  LBPKeySink u_key0 (
    .in(B[0])
  );

  LBPKeySink u_key7 (
    .in(B[7])
  );

  LBPKeySink u_key8 (
    .in(B[8])
  );
endmodule
