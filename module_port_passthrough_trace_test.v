module MPKeySrc(output out);
  assign out = 1'b1;
endmodule

module MPKeySink(input in);
endmodule

module MPPass(input i, output o);
  assign o = i;
endmodule

module MPDriverChild(input a);
endmodule

module MPLoadChild(output y);
  assign y = 1'b0;
endmodule

module ModulePortPassthroughTop;
  wire key_to_pass;
  wire pass_to_assign;
  wire assign_to_child;

  MPKeySrc u_key_src(.out(key_to_pass));
  MPPass u_driver_pass(.i(key_to_pass), .o(pass_to_assign));
  assign assign_to_child = pass_to_assign;
  MPDriverChild u_driver_child(.a(assign_to_child));

  wire child_to_pass;
  wire pass_to_sink;

  MPLoadChild u_load_child(.y(child_to_pass));
  MPPass u_load_pass(.i(child_to_pass), .o(pass_to_sink));
  MPKeySink u_key_sink(.in(pass_to_sink));
endmodule
