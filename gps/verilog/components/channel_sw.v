`include "global.vh"
`include "channel.vh"
`include "channel__ca_upsampler.vh"
`include "channel__tracking_loops.vh"
//`include "top__channel.vh"

`include "subchannel.vh"
`include "ca_upsampler.vh"

`define DEBUG
`include "debug.vh"

module channel_sw(
    input                    clk,
    input                    reset,
    //Real-time sample interface.
    input                    data_available,
    input [`INPUT_RANGE]     data,
    //Slot control.
    input                    init,
    input [`PRN_RANGE]       prn,
    output                   slot_available,
    //Accumulation results.
    output wire              acc_valid,
    output wire [`PRN_RANGE] acc_tag,
    output wire [`ACC_RANGE] i_early,
    output wire [`ACC_RANGE] q_early,
    output wire [`ACC_RANGE] i_prompt,
    output wire [`ACC_RANGE] q_prompt,
    output wire [`ACC_RANGE] i_late,
    output wire [`ACC_RANGE] q_late,
    //Tracking result memory interface.
    //FIXME Bit ranges.
    output wire [1:0]        track_mem_addr,
    output wire              track_mem_wr_en,
    input [37:0]             track_mem_data_in,
    output wire [37:0]       track_mem_data_out);
   
   //Cycle through PRN slots in channel.
   //The slot number indicates which slot
   //is in pipeline stage 0.
   //FIXME Add defines for this somewhere.
   localparam NUM_SLOTS = 2;
   localparam [1:0] MAX_SLOT = NUM_SLOTS-1;
   reg [1:0] slot;
   reg       active;
   always @(posedge clk) begin
      slot <= reset ? 2'd0 :
              !active ? slot :
              slot==MAX_SLOT ? 2'd0 :
              slot+2'd1;

      active <= reset ? 1'b0 :
                data_available ? 1'b1 :
                slot==MAX_SLOT ? 1'b0 :
                active;
   end // always @ (posedge clk)

   //Select next available slot.
   reg [(NUM_SLOTS-1):0] slot_active;
   wire [(NUM_SLOTS-1):0] next_slot;
   priority_select #(.NUM_ENTRIES(NUM_SLOTS))
     slot_select(.eligible(~slot_active),
                 .select_oh(next_slot));

   //Start next-available slot when initialization
   //requested from top level.
   reg [`PRN_RANGE] slot_prn[(NUM_SLOTS-1):0];
   reg [(NUM_SLOTS-1):0] slot_init_pending;
   `KEEP wire [(NUM_SLOTS-1):0] clear_init;
   genvar i;
   generate
      for(i=0;i<NUM_SLOTS;i=i+1) begin : slot_status_gen
         always @(posedge clk) begin
            slot_active[i] <= reset ? 1'b0 :
                              init && next_slot[i] ? 1'b1 :
                              slot_active[i];

            slot_prn[i] <= reset ? `PRN_WIDTH'd0 :
                           init && next_slot[i] ? prn :
                           slot_prn[i];

            slot_init_pending[i] <= reset ? 1'b0 :
                                    clear_init[i] ? 1'b0 :
                                    init && next_slot[i] ? 1'b1 :
                                    slot_init_pending[i];
         end
      end
   endgenerate

   //Assert slot available flag to top level to clear
   //initializaiton request.
   assign slot_available = |(~slot_active);

   //Flag accumulation completion when enough
   //samples have been accumulated.
   //FIXME Does the sample count have to be loaded
   //      from the slot state memory as well? Each
   //      slot can initialize and complete accumulations
   //      at a different time.
   wire [`SAMPLE_COUNT_TRACK_RANGE] tau_prime_k;
   reg [`SAMPLE_COUNT_TRACK_RANGE] sample_count;
   reg                             acc_complete_km1;
   always @(posedge clk) begin
      sample_count <= reset ? `SAMPLE_COUNT_TRACK_WIDTH'd0 :
                      !data_available ? sample_count :
                      acc_complete_km1 ? `SAMPLE_COUNT_TRACK_WIDTH'd0 :
                      sample_count+`SAMPLE_COUNT_TRACK_WIDTH'd1;

      acc_complete_km1 <= reset ? 1'b0 :
                          sample_count==tau_prime_k-`SAMPLE_COUNT_TRACK_WIDTH'd1 ? 1'b1 :
                          1'b0;
   end // always @ (posedge clk)

   //FIXME Get tau_prime value from tracking loops.
   assign tau_prime_k = `SAMPLE_COUNT_TRACK_MAX;

   //Clear the accumulators on the first sample.
   wire clear;
   assign clear = sample_count==`SAMPLE_COUNT_TRACK_WIDTH'd0;

   //////////////////////////////
   // Channel Slot State Memory
   //////////////////////////////

   //Note: The channel slot memories are flopped
   //      on both the inputs and outputs. This
   //      means that the results are not available
   //      for 2 cycles after doing a read.
   
   //Slot state memory.
   //FIXME Add define for this.
   `KEEP wire         slot_mem_wr_en;
   `KEEP wire [1:0]   slot_mem_wr_addr;
   `KEEP wire [105:0] slot_mem_in;
   `KEEP wire [1:0]   slot_mem_rd_addr;
   `KEEP wire [105:0] slot_mem_out;
   channel_slot_mem #(.DEPTH(2),
                      .ADDR_WIDTH(2),
                      .DATA_WIDTH(106))
     slot_mem(.clock(clk),
              .aclr(reset),
	      .wren(slot_mem_wr_en),
	      .wraddress(slot_mem_wr_addr),
	      .data(slot_mem_in),
	      .rdaddress(slot_mem_rd_addr),
	      .q(slot_mem_out));
   
   //Accumulator state memory.
   //FIXME Add define for this.
   `KEEP wire         acc_mem_wr_en;
   `KEEP wire [1:0]   acc_mem_wr_addr;
   `KEEP wire [119:0] acc_mem_in;
   `KEEP wire [1:0]   acc_mem_rd_addr;
   `KEEP wire [119:0] acc_mem_out;
   channel_slot_mem #(.DEPTH(2),
                      .ADDR_WIDTH(2),
                      .DATA_WIDTH(6*`ACC_WIDTH))//FIXME
     acc_mem(.clock(clk),
             .aclr(reset),
	     .wren(acc_mem_wr_en),
	     .wraddress(acc_mem_wr_addr),
	     .data(acc_mem_in),
	     .rdaddress(acc_mem_rd_addr),
	     .q(acc_mem_out));

   ///////////////////////////////////
   // Pipeline Stage 0:
   //   --Fetch slot state.
   //   --Fetch slot tracking results.
   ///////////////////////////////////

   //Fetch current slot's state.
   assign slot_mem_rd_addr = slot;

   //Fetch current slot's tracking results.
   //FIXME Need to write initial Doppler/code rate into
   //FIXME memory on init, but slot_init_pending might not
   //FIXME be set until stage 1. How to deal with this?
   assign track_mem_addr = slot;
   assign track_mem_wr_en = 1'b0;
   assign track_mem_data_out = 38'd0;
   
   `KEEP wire [1:0] slot_km1;
   delay #(.WIDTH(2))
     slot_delay_0(.clk(clk),
                  .reset(reset),
                  .in(slot),
                  .out(slot_km1));

   `KEEP wire active_km1;
   delay active_delay_0(.clk(clk),
                        .reset(reset),
                        .in(active && slot_active[slot]),
                        .out(active_km1));

   `KEEP wire [`INPUT_RANGE] data_km1;
   delay #(.WIDTH(`INPUT_WIDTH))
     data_delay_0(.clk(clk),
                  .reset(reset),
                  .in(data),
                  .out(data_km1));

   ///////////////////////////////////
   // Pipeline Stage 1:
   //   --Wait for slot state.
   //   --Wait for tracking results.
   ///////////////////////////////////
   
   `KEEP wire [1:0] slot_km2;
   delay #(.WIDTH(2))
     slot_delay_1(.clk(clk),
                  .reset(reset),
                  .in(slot_km1),
                  .out(slot_km2));

   `KEEP wire active_km2;
   delay active_delay_1(.clk(clk),
                        .reset(reset),
                        .in(active_km1),
                        .out(active_km2));

   `KEEP wire [`INPUT_RANGE] data_km2;
   delay #(.WIDTH(`INPUT_WIDTH))
     data_delay_1(.clk(clk),
                  .reset(reset),
                  .in(data_km1),
                  .out(data_km2));

   //////////////////////////////
   // Pipeline Stage 2:
   //   --Update carrier DDS.
   //   --Update code DDS.
   //////////////////////////////

   //Decode state memory output.
   //FIXME Make defines for these.
   //FIXME Get init values from startup C/A upsampler.
   `KEEP wire [`CARRIER_ACC_RANGE]  carrier_acc_in;
   `KEEP wire [`CS_RANGE]           code_shift_in;
   `KEEP wire [`CA_ACC_RANGE]       ca_clk_acc_in;
   `KEEP wire                       ca_clk_hist_in;
   `KEEP wire [`CA_CHIP_HIST_RANGE] prompt_chip_hist_in;
   `KEEP wire [`CA_CHIP_HIST_RANGE] late_chip_hist_in;
   `KEEP wire [10:1]                g1_in;
   `KEEP wire [10:1]                g2_in;
   `KEEP wire [`CA_CS_RANGE]        ca_code_shift_in;
   assign g1_in = slot_init_pending[slot_km2] ? 10'h3FF : slot_mem_out[105:96];
   assign g2_in = slot_init_pending[slot_km2] ? 10'h3FF : slot_mem_out[95:86];
   assign ca_code_shift_in = slot_init_pending[slot_km2] ? `CA_CS_WIDTH'd0 : slot_mem_out[85:76];
   assign carrier_acc_in = slot_init_pending[slot_km2] ? `CARRIER_ACC_WIDTH'd0 : slot_mem_out[75:49];
   assign code_shift_in = slot_init_pending[slot_km2] ? `CS_RESET_VALUE : slot_mem_out[48:34];
   assign ca_clk_acc_in = slot_init_pending[slot_km2] ? `CA_ACC_WIDTH'd0 : slot_mem_out[33:9];
   assign ca_clk_hist_in = slot_init_pending[slot_km2] ? 1'b1 : slot_mem_out[8];
   assign prompt_chip_hist_in = slot_init_pending[slot_km2] ? `CA_CHIP_HIST_WIDTH'b0 : slot_mem_out[7:4];
   assign late_chip_hist_in = slot_init_pending[slot_km2] ? `CA_CHIP_HIST_WIDTH'b0 : slot_mem_out[3:0];

   //FIXME On init write initial Doppler and code shift (needed?)
   //FIXME values INTO tracking loop M4K. This is the only instance
   //FIXME where the channel writes to that memory. This means that
   //FIXME the channel-side port must be read/write.

   //Clear init flags.
   generate
      for(i=0;i<NUM_SLOTS;i=i+1) begin : slot_init_clear_gen
         assign clear_init[i] = active_km2 && slot_km2==i && slot_init_pending[i];
      end
   endgenerate
   
   //Fetch tracking results from memory.
   //FIXME Ranges.
   wire [`DOPPLER_INC_RANGE] doppler_dphi;
   wire [`CA_PHASE_INC_RANGE] ca_dphi;
   assign ca_dphi = track_mem_data_in[37:18];
   assign doppler_dphi = track_mem_data_in[17:0];

   //Carrier value is front-end intermediate frequency plus
   //sign-extended version of two's complement Doppler shift.
   
   wire [`CARRIER_PHASE_INC_RANGE] f_carrier;
   assign f_carrier = `MIXING_SIGN ?
                      `F_IF_INC-{{`DOPPLER_PAD_SIZE{doppler_dphi[`DOPPLER_INC_WIDTH-1]}},doppler_dphi} :
                      `F_IF_INC+{{`DOPPLER_PAD_SIZE{doppler_dphi[`DOPPLER_INC_WIDTH-1]}},doppler_dphi};

   //Generate the carrier frequency.
   //Note: This DDS module is internally pipelined
   //      by 1 cycle. The result is ready in stage 3.
   wire [`CARRIER_LUT_INDEX_RANGE] carrier_index_km3;
   wire [`CARRIER_ACC_RANGE]       carrier_acc_out_km3;
   dds_sw #(.ACC_WIDTH(`CARRIER_ACC_WIDTH),
            .PHASE_INC_WIDTH(`CARRIER_PHASE_INC_WIDTH),
            .OUTPUT_WIDTH(`CARRIER_LUT_INDEX_WIDTH),
            .PIPELINE(1))
     carrier_generator(.clk(clk),
                       .reset(reset),
                       .enable(active_km2),
                       .acc_in(carrier_acc_in),
                       .acc_out(carrier_acc_out_km3),
                       .inc(f_carrier),
                       .out(carrier_index_km3));

   //Generate the upsampled C/A code.
   //Note: The C/A upsampler is internally pipelined.
   //      The C/A bits are ready in stage 3.
   `KEEP wire ca_bit_early_km3, ca_bit_prompt_km3, ca_bit_late_km3;
   `KEEP wire [`CS_RANGE]           code_shift_out;
   `KEEP wire [`CA_ACC_RANGE]       ca_clk_acc_out;
   `KEEP wire                       ca_clk_hist_out;
   `KEEP wire [`CA_CHIP_HIST_RANGE] prompt_chip_hist_out_km3;
   `KEEP wire [`CA_CHIP_HIST_RANGE] late_chip_hist_out_km3;
   `KEEP wire [10:1]                g1_out_km3;
   `KEEP wire [10:1]                g2_out_km3;
   `KEEP wire [`CA_CS_RANGE]        ca_code_shift_out_km3;
   ca_upsampler_sw upsampler(.clk(clk),
                             .reset(reset),
                             //Control interface.
                             .prn(slot_prn[slot_km2]),
                             .ca_dphi(ca_dphi),
                             //C/A code output interface.
                             .out_early(ca_bit_early_km3),
                             .out_prompt(ca_bit_prompt_km3),
                             .out_late(ca_bit_late_km3),
                             //C/A upsampler state.
                             .code_shift_in(code_shift_in),
                             .ca_clk_acc_in(ca_clk_acc_in),
                             .ca_clk_hist_in(ca_clk_hist_in),
                             .prompt_chip_hist_in(prompt_chip_hist_in),
                             .late_chip_hist_in(late_chip_hist_in),
                             .code_shift_out(code_shift_out),
                             .ca_clk_acc_out(ca_clk_acc_out),
                             .ca_clk_hist_out(ca_clk_hist_out),
                             .prompt_chip_hist_out(prompt_chip_hist_out_km3),
                             .late_chip_hist_out(late_chip_hist_out_km3),
                             //C/A generator state.
                             .g1_in(g1_in),
                             .g2_in(g2_in),
                             .ca_code_shift_in(ca_code_shift_in),
                             .g1_out(g1_out_km3),
                             .g2_out(g2_out_km3),
                             .ca_code_shift_out(ca_code_shift_out_km3));

   //Pipe C/A upsampler state to next stage.
   `KEEP wire [1:0] slot_km3;
   delay #(.WIDTH(2))
     slot_delay_2(.clk(clk),
                  .reset(reset),
                  .in(slot_km2),
                  .out(slot_km3));
   
   `KEEP wire active_km3;
   delay active_delay_2(.clk(clk),
                        .reset(reset),
                        .in(active_km2),
                        .out(active_km3));
   
   wire [`CS_RANGE] code_shift_out_km3;
   delay #(.WIDTH(`CS_WIDTH))
     code_shift_delay(.clk(clk),
                      .reset(reset),
                      .in(code_shift_out),
                      .out(code_shift_out_km3));
   
   wire [`CA_ACC_RANGE] ca_clk_acc_out_km3;
   delay #(.WIDTH(`CA_ACC_WIDTH))
     ca_clk_acc_delay(.clk(clk),
                      .reset(reset),
                      .in(ca_clk_acc_out),
                      .out(ca_clk_acc_out_km3));
   
   wire ca_clk_hist_out_km3;
   delay ca_clk_hist_delay(.clk(clk),
                           .reset(reset),
                           .in(ca_clk_hist_out),
                           .out(ca_clk_hist_out_km3));

   //Delay data until next stage.
   `KEEP wire [`INPUT_RANGE] data_km3;
   delay #(.WIDTH(`INPUT_WIDTH))
     data_delay(.clk(clk),
                .reset(reset),
                .in(data_km2),
                .out(data_km3));

   `KEEP wire init_pending_km3;
   delay init_delay_2(.clk(clk),
                      .reset(reset),
                      .in(slot_init_pending[slot_km2]),
                      .out(init_pending_km3));

   ///////////////////////////////////
   // Pipeline Stage 3:
   //   --Update slot state.
   //   --Generate carrier signals.
   //   --Wipe-off carrier.
   ///////////////////////////////////

   //Write slot state to memory.
   assign slot_mem_in[105:96] = g1_out_km3;
   assign slot_mem_in[95:86] = g2_out_km3;
   assign slot_mem_in[85:76] = ca_code_shift_out_km3;
   assign slot_mem_in[75:49] = carrier_acc_out_km3;
   assign slot_mem_in[48:34] = code_shift_out_km3;
   assign slot_mem_in[33:9] = ca_clk_acc_out_km3;
   assign slot_mem_in[8] = ca_clk_hist_out_km3;
   assign slot_mem_in[7:4] = prompt_chip_hist_out_km3;
   assign slot_mem_in[3:0] = late_chip_hist_out_km3;

   assign slot_mem_wr_en = active_km3;
   assign slot_mem_wr_addr = slot_km3;

   //Generate in-phase (cos) and quadrature (sin)
   //carrier signals.
   `KEEP wire [`CARRIER_LUT_RANGE] carrier_i;
   cos carrier_cos_lut(.in(carrier_index_km3),
                       .out(carrier_i));
   
   `KEEP wire [`CARRIER_LUT_RANGE] carrier_q;
   sin carrier_sin_lut(.in(carrier_index_km3),
                       .out(carrier_q));

   //Wipe off carrier in-phase and quadrature
   //carriers.
   `KEEP wire [`SIG_NO_CARRIER_RANGE] sig_no_carrier_i;
   mult carrier_mux_i(.carrier(carrier_i),
                      .signal(data_km3),
                      .out(sig_no_carrier_i));
   
   `KEEP wire [`SIG_NO_CARRIER_RANGE] sig_no_carrier_q;
   mult carrier_mux_q(.carrier(carrier_q),
                      .signal(data_km3),
                      .out(sig_no_carrier_q));

   //Pipe post-carrier wipe signals to stage 4.
   `KEEP wire [`SIG_NO_CARRIER_RANGE] sig_no_carrier_i_km4;
   delay #(.WIDTH(`SIG_NO_CARRIER_WIDTH))
     post_carrier_i_delay(.clk(clk),
                          .reset(reset),
                          .in(sig_no_carrier_i),
                          .out(sig_no_carrier_i_km4));
   
   `KEEP wire [`SIG_NO_CARRIER_RANGE] sig_no_carrier_q_km4;
   delay #(.WIDTH(`SIG_NO_CARRIER_WIDTH))
     post_carrier_q_delay(.clk(clk),
                          .reset(reset),
                          .in(sig_no_carrier_q),
                          .out(sig_no_carrier_q_km4));

   //Pipe code bits to stage 4.
   wire ca_bit_early_km4, ca_bit_prompt_km4, ca_bit_late_km4;
   delay #(.WIDTH(3))
     post_carrier_code_delay(.clk(clk),
                             .reset(reset),
                             .in({ca_bit_early_km3,ca_bit_prompt_km3,ca_bit_late_km3}),
                             .out({ca_bit_early_km4,ca_bit_prompt_km4,ca_bit_late_km4}));

   //Pipe slot control to next stage.
   `KEEP wire [1:0] slot_km4;
   delay #(.WIDTH(2))
     slot_delay_3(.clk(clk),
                  .reset(reset),
                  .in(slot_km3),
                  .out(slot_km4));
   
   `KEEP wire active_km4;
   delay active_delay_3(.clk(clk),
                        .reset(reset),
                        .in(active_km3),
                        .out(active_km4));

   //Pipe clear signal from stage 0 to stage 4.
   wire clear_km4;
   delay #(.DELAY(4))
     clear_delay(.clk(clk),
                 .reset(reset),
                 .in(clear),
                 .out(clear_km4));

   `KEEP wire init_pending_km4;
   delay init_delay_3(.clk(clk),
                      .reset(reset),
                      .in(init_pending_km3),
                      .out(init_pending_km4));

   /////////////////////////////////////////////
   // Pipeline Stage 4:
   //   --Wipe-off code.
   //   --Accumulate result.
   //   --Take I/Q absolute values.
   /////////////////////////////////////////////

   //Decode accumulator memory output.
   //FIXME Make defines for these.
   `KEEP wire [`ACC_RANGE] acc_i_early_in;
   `KEEP wire [`ACC_RANGE] acc_q_early_in;
   `KEEP wire [`ACC_RANGE] acc_i_prompt_in;
   `KEEP wire [`ACC_RANGE] acc_q_prompt_in;
   `KEEP wire [`ACC_RANGE] acc_i_late_in;
   `KEEP wire [`ACC_RANGE] acc_q_late_in;
   assign acc_i_early_in = acc_mem_out[119:100];
   assign acc_q_early_in = acc_mem_out[99:80];
   assign acc_i_prompt_in = acc_mem_out[79:60];
   assign acc_q_prompt_in = acc_mem_out[59:40];
   assign acc_i_late_in = acc_mem_out[39:20];
   assign acc_q_late_in = acc_mem_out[19:0];
   
   //Note: The subchannels are internally pipelined.
   //      The results are ready in stage 5.

   //Early subchannel.
   `KEEP wire [`ACC_RANGE] acc_i_early_out_km5;
   `KEEP wire [`ACC_RANGE] acc_q_early_out_km5;
   subchannel_sw #(.INPUT_WIDTH(`SIG_NO_CARRIER_WIDTH),
                   .OUTPUT_WIDTH(`ACC_WIDTH))
     subchannel_early(.clk(clk),
                      .reset(reset),
                      .clear(clear_km4 || init_pending_km4),
                      .ca_bit(ca_bit_early_km4),
                      .data_i(sig_no_carrier_i_km4),
                      .data_q(sig_no_carrier_q_km4),
                      .accumulator_i_in(acc_i_early_in),
                      .accumulator_q_in(acc_q_early_in),
                      .accumulator_i_out(acc_i_early_out_km5),
                      .accumulator_q_out(acc_q_early_out_km5));

   //Prompt subchannel.
   `KEEP wire [`ACC_RANGE] acc_i_prompt_out_km5;
   `KEEP wire [`ACC_RANGE] acc_q_prompt_out_km5;
   subchannel_sw #(.INPUT_WIDTH(`SIG_NO_CARRIER_WIDTH),
                   .OUTPUT_WIDTH(`ACC_WIDTH))
     subchannel_prompt(.clk(clk),
                       .reset(reset),
                       .clear(clear_km4 || init_pending_km4),
                       .ca_bit(ca_bit_prompt_km4),
                       .data_i(sig_no_carrier_i_km4),
                       .data_q(sig_no_carrier_q_km4),
                       .accumulator_i_in(acc_i_prompt_in),
                       .accumulator_q_in(acc_q_prompt_in),
                       .accumulator_i_out(acc_i_prompt_out_km5),
                       .accumulator_q_out(acc_q_prompt_out_km5));

   //Late subchannel.
   `KEEP wire [`ACC_RANGE] acc_i_late_out_km5;
   `KEEP wire [`ACC_RANGE] acc_q_late_out_km5;
   subchannel_sw #(.INPUT_WIDTH(`SIG_NO_CARRIER_WIDTH),
                   .OUTPUT_WIDTH(`ACC_WIDTH))
     subchannel_late(.clk(clk),
                     .reset(reset),
                     .clear(clear_km4 || init_pending_km4),
                     .ca_bit(ca_bit_late_km4),
                     .data_i(sig_no_carrier_i_km4),
                     .data_q(sig_no_carrier_q_km4),
                     .accumulator_i_in(acc_i_late_in),
                     .accumulator_q_in(acc_q_late_in),
                     .accumulator_i_out(acc_i_late_out_km5),
                     .accumulator_q_out(acc_q_late_out_km5));

   //Pipe slot control to next stage.
   `KEEP wire [1:0] slot_km5;
   delay #(.WIDTH(2))
     slot_delay_4(.clk(clk),
                  .reset(reset),
                  .in(slot_km4),
                  .out(slot_km5));
   
   `KEEP wire active_km5;
   delay active_delay_4(.clk(clk),
                        .reset(reset),
                        .in(active_km4),
                        .out(active_km5));

   /////////////////////////////////////////////
   // Pipeline Stage 5:
   //   --Write back to accumulator memory.
   //   --Flag accumulation valid.
   /////////////////////////////////////////////

   //Write accumulator state to memory.
   assign acc_mem_in[119:100] = acc_i_early_out_km5;
   assign acc_mem_in[99:80] = acc_q_early_out_km5;
   assign acc_mem_in[79:60] = acc_i_prompt_out_km5;
   assign acc_mem_in[59:40] = acc_q_prompt_out_km5;
   assign acc_mem_in[39:20] = acc_i_late_out_km5;
   assign acc_mem_in[19:0] = acc_q_late_out_km5;

   assign acc_mem_wr_en = active_km5;
   assign acc_mem_wr_addr = slot_km5;

   //Output accumulation results to tracking loops.
   assign i_early = acc_i_early_out_km5;
   assign q_early = acc_q_early_out_km5;
   assign i_prompt = acc_i_prompt_out_km5;
   assign q_prompt = acc_q_prompt_out_km5;
   assign i_late = acc_i_late_out_km5;
   assign q_late = acc_q_late_out_km5;
   
   //Assert accumulation valid to tracking loops
   //at the end of an accumulation period.
   delay #(.DELAY(4))
     acc_valid_delay(.clk(clk),
                     .reset(reset),
                     .in(acc_complete_km1),
                     .out(acc_valid));

   //FIXME Pipe PRN to acc_tag.
   assign acc_tag = `PRN_WIDTH'd0;
   
endmodule