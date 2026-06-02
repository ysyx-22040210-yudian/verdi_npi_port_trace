module AssignPassKey(
  output out
);
  wire src;
  assign src = 1'b1;
  assign out = src;
endmodule

module AssignPassTarget(
  input a,
  input direct
);
endmodule

module AssignPassTop;
  wire key_out;
  wire mid1;
  wire mid0;
  wire direct_mid;
  wire direct_key_out;

  AssignPassKey u_key_chain(
    .out(key_out)
  );

  AssignPassKey u_key_direct(
    .out(direct_key_out)
  );

  assign mid1 = key_out;
  assign mid0 = mid1;
  assign direct_mid = direct_key_out;

  AssignPassTarget u_child(
    .a(mid0),
    .direct(direct_mid)
  );
endmodule
