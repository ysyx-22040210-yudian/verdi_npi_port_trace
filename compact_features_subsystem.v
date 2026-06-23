module CFSubsystem #(
  parameter integer SID = 0
) (
  input clk,
  input tie_parent
);
  wire [3:0] key_bits;
  wire [3:0] drv_bits;
  wire key_chain;
  wire chain_mid0;
  wire chain_mid1;
  wire key_port_src;
  wire port_mid;
  wire ternary_cond;
  wire ternary_noise;
  wire ternary_net;
  wire noise;
  wire reg_q;
  wire [7:0] load_bus;
  wire load_port;
  wire load_reg;
  wire load_no;
  wire [3:0] load_low;
  wire [3:0] load_high;
  wire [4:0] load_concat;
  wire load_port_mid;
  wire sink_low_used;
  wire sink_high_used;
  wire sink_concat_used;
  wire sink_port_used;
  wire sink_reg_used;
  wire nonkey_used;
  wire aux_in_mid;
  wire aux_out;
  wire aux_sink_used;

  CFKeySrc #(.W(4), .VALUE(32'hA)) u_key_bits(.out(key_bits));
  assign drv_bits = {1'b1, key_bits[2], 1'b0, key_bits[0]};

  CFKeySrc #(.W(1), .VALUE(32'h1)) u_key_chain(.out(key_chain));
  assign chain_mid0 = key_chain;
  assign chain_mid1 = chain_mid0;

  CFKeySrc #(.W(1), .VALUE(32'h1)) u_key_port(.out(key_port_src));
  CFPass #(.W(1)) u_driver_pass(.i(key_port_src), .o(port_mid));

  CFKeySrc #(.W(1), .VALUE(32'h1)) u_key_ternary_cond(.out(ternary_cond));
  CFNoise u_ternary_noise(.n(ternary_noise));
  assign ternary_net = ternary_cond ? ternary_noise : 1'b1;

  CFNoise u_noise(.n(noise));
  CFRegSource u_reg_source(.clk(clk), .q(reg_q));

  CFShell1 #(.ID(SID), .DW(8)) u_shell1 (
    .clk(clk),
    .drv_bits(drv_bits),
    .drv_chain(chain_mid1),
    .drv_port(port_mid),
    .drv_ternary_stop(ternary_net),
    .drv_const(tie_parent),
    .drv_reg(reg_q),
    .drv_float(),
    .drv_noise(noise),
    .load_bus(load_bus),
    .load_port(load_port),
    .load_reg(load_reg),
    .load_no(load_no)
  );

  assign load_low = load_bus[3:0];
  assign load_high = load_bus[7:4];
  assign load_concat = {load_bus[2:0], load_bus[6:5]};
  CFKeySink #(.W(4)) u_sink_low(.in(load_low), .used(sink_low_used));
  CFKeySink #(.W(4)) u_sink_high(.in(load_high), .used(sink_high_used));
  CFKeySink #(.W(5)) u_sink_concat(.in(load_concat), .used(sink_concat_used));

  CFPass #(.W(1)) u_load_pass(.i(load_port), .o(load_port_mid));
  CFKeySink #(.W(1)) u_sink_port(.in(load_port_mid), .used(sink_port_used));
  CFKeySink #(.W(1)) u_sink_reg(.in(load_reg), .used(sink_reg_used));
  CFNonKeySink u_nonkey_load(.i(load_no), .used(nonkey_used));

  assign aux_in_mid = key_chain;
  CFAuxTarget #(.MODE(SID + 10)) u_aux (
    .aux_in(aux_in_mid),
    .aux_float(),
    .aux_out(aux_out),
    .aux_unused()
  );
  CFKeySink #(.W(1)) u_aux_sink(.in(aux_out), .used(aux_sink_used));
endmodule
