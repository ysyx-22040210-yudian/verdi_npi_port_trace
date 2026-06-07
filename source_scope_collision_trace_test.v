module CollisionKeyword(
  output out
);
  assign out = 1'b1;
endmodule

module CollisionNonKeyword(
  output out
);
  assign out = 1'b0;
endmodule

module CollisionProbe(
  input drv_collision,
  input drv_real
);
endmodule

module CollisionDecoySameNames(
  input key_net,
  output b_collision
);
  assign b_collision = key_net;
endmodule

module SourceScopeCollisionTop;
  wire key_net;
  wire c_nonkey;
  wire b_collision;
  wire b_real;

  CollisionKeyword u_key_decoy(
    .out(key_net)
  );

  CollisionNonKeyword u_nonkey(
    .out(c_nonkey)
  );

  assign b_collision = c_nonkey;
  assign b_real = key_net;

  CollisionProbe u_probe(
    .drv_collision(b_collision),
    .drv_real(b_real)
  );
endmodule
