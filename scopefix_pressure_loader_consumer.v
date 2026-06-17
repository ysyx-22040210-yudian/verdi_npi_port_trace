module SFPLoaderConsumer (
  input c,
  input [31:0] bus,
  input orphan
);
  wire net;
  wire chain_mid0;
  wire chain_mid1;
  wire [10:0] slice_low;
  wire [9:0] slice_mid;
  wire [10:0] slice_high;
  wire [15:0] concat_mid0;
  wire [15:0] concat_mid1;
  wire key_used0;
  wire key_used1;
  wire key_used2;
  wire key_used3;
  wire key_used4;
  reg reg_endpoint;

  assign net = c;
  assign chain_mid0 = net;
  assign chain_mid1 = chain_mid0;

  SFPKeySink #(.ID(10), .WIDTH(1)) u_key_chain(
    .in(chain_mid1),
    .used(key_used0)
  );

  assign slice_low = bus[10:0];
  assign slice_mid = bus[20:11];
  assign slice_high = bus[31:21];

  SFPKeySink #(.ID(11), .WIDTH(11)) u_key_low(
    .in(slice_low),
    .used(key_used1)
  );

  assign concat_mid0 = {slice_mid[4:0], bus[7:0], c, orphan, 1'b0};
  assign concat_mid1 = {concat_mid0[7:0], slice_high[7:0]};

  SFPKeySink #(.ID(12), .WIDTH(16)) u_key_concat(
    .in(concat_mid1),
    .used(key_used2)
  );

  always @(*) begin
    reg_endpoint = chain_mid1 | bus[0];
  end

  SFPKeySink #(.ID(13), .WIDTH(1)) u_key_regmix(
    .in(reg_endpoint),
    .used(key_used3)
  );

  SFPKeySink #(.ID(14), .WIDTH(1)) u_key_orphan(
    .in(orphan),
    .used(key_used4)
  );
endmodule
