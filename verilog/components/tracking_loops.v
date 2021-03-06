// This file is part of the Cornell University Hardware GPS Receiver Project.
// Copyright (C) 2009 - Adam Shapiro (ams348@cornell.edu)
//                      Tom Chatt (tjc42@cornell.edu)
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
`include "global.vh"
`include "tracking_loops.vh"
`include "channel__dll.vh"
`include "channel__tracking_loops.vh"

`define DEBUG
`include "debug.vh"

module tracking_loops(
    input                             clk,
    input                             reset,
    //Channel 0 history.
    input                             i2q2_valid_0,                             
    input [`I2Q2_RANGE]               i2q2_early_k_0,
    input [`I2Q2_RANGE]               i2q2_prompt_k_0,
    input [`I2Q2_RANGE]               i2q2_late_k_0,
    input [`IQ_RANGE]                 iq_prompt_km1_0,
    input [`ACC_RANGE_TRACK]          i_prompt_k_0,
    input [`ACC_RANGE_TRACK]          q_prompt_k_0,
    input [`ACC_RANGE_TRACK]          i_prompt_km1_0,
    input [`ACC_RANGE_TRACK]          q_prompt_km1_0,
    input [`W_DF_RANGE]               w_df_k_0,
    input [`W_DF_DOT_RANGE]           w_df_dot_k_0,
    //Channel 0 tracking results.
    output reg                        tracking_ready_0,
    output reg [`IQ_RANGE]            iq_prompt_k_0,
    output reg [`DOPPLER_INC_RANGE]   doppler_inc_kp1_0,
    output reg [`W_DF_RANGE]          w_df_kp1_0,
    output reg [`W_DF_DOT_RANGE]      w_df_dot_kp1_0,
    output reg [`CA_PHASE_INC_RANGE]  ca_dphi_kp1_0,
    output reg [`DLL_TAU_RANGE]       tau_prime_kp1_0);

   `KEEP wire channel_0_starting;
   `PRESERVE reg channel_0_pending;
   always @(posedge clk) begin
      channel_0_pending <= reset ? 1'b0 :
                           i2q2_valid_0 ? 1'b1 :
                           channel_0_starting ? 1'b0 :
                           channel_0_pending;
   end
   
   ////////////////////
   // IQ Computation
   ////////////////////

   //Compute IQ values for selected channel.
   wire             iq_early_start;
   wire             iq_early_ready;
   wire [`IQ_RANGE] iq_early_k_value;
   wire             sq_early_in_use;
   sqrt_fixed sqrt_early(.clk(clk),
                         .reset(reset),
                         .input_ready(channel_0_pending),
                         .in(i2q2_early_k_0[`I2Q2_RANGE_TRACK]),
                         .flag_new_input(iq_early_start),
                         .output_ready(iq_early_ready),
                         .in_use(sq_early_in_use),
                         .out(iq_early_k_value));

   wire             iq_prompt_start;
   wire             iq_prompt_ready;
   wire [`IQ_RANGE] iq_prompt_k_value;
   wire             sq_prompt_in_use;
   sqrt_fixed sqrt_prompt(.clk(clk),
                          .reset(reset),
                          .input_ready(channel_0_pending),
                          .in(i2q2_prompt_k_0[`I2Q2_RANGE_TRACK]),
                          .flag_new_input(iq_prompt_start),
                          .output_ready(iq_prompt_ready),
                          .in_use(sq_prompt_in_use),
                          .out(iq_prompt_k_value));

   wire             iq_late_start;
   wire             iq_late_ready;
   wire [`IQ_RANGE] iq_late_k_value;
   wire             sq_late_in_use;
   sqrt_fixed sqrt_late(.clk(clk),
                        .reset(reset),
                        .input_ready(channel_0_pending),
                        .in(i2q2_late_k_0[`I2Q2_RANGE_TRACK]),
                        .flag_new_input(iq_late_start),
                        .output_ready(iq_late_ready),
                        .in_use(sq_late_in_use),
                        .out(iq_late_k_value));

   //Note: All square root functions are synchronized.
   //      They all should start at the same time.
   assign channel_0_starting = iq_prompt_start;

   //Note: All square root functions are synchronized.
   //      They all should finish at the same time.
   `KEEP wire iq_values_ready;
   assign iq_values_ready = iq_prompt_ready;

   //Store IQ values returned by square roots.
   reg [`IQ_RANGE] iq_early_k;
   reg [`IQ_RANGE] iq_prompt_k;
   reg [`IQ_RANGE] iq_late_k;
   always @(posedge clk) begin
      iq_early_k <= reset ? `IQ_WIDTH'h0 :
                    iq_values_ready ? iq_early_k_value :
                    iq_early_k;
      
      iq_prompt_k <= reset ? `IQ_WIDTH'h0 :
                     iq_values_ready ? iq_prompt_k_value :
                     iq_prompt_k;
      
      iq_late_k <= reset ? `IQ_WIDTH'h0 :
                   iq_values_ready ? iq_late_k_value :
                   iq_late_k;
   end // always @ (posedge clk)
   
   //Assert start to each loop until accepted.
   `KEEP wire          fll_starting;
   `KEEP wire          dll_starting;
   `PRESERVE reg [1:0] loop_start_status;
   always @(posedge clk) begin
      loop_start_status <= reset ? 2'h0 :
                               iq_values_ready ? 2'b11 :
                               fll_starting ? loop_start_status & ~2'b10 :
                               dll_starting ? loop_start_status & ~2'b01 :
                               loop_start_status;
   end
   
   ////////////////////
   // Tracking Loops
   ////////////////////

   //Frequency-locked loop.
   `KEEP wire                      fll_result_ready;
   `KEEP wire [`CHANNEL_ID_RANGE]  fll_result_tag;
   `KEEP wire [`DOPPLER_INC_RANGE] doppler_inc_kp1;
   `KEEP wire [`W_DF_RANGE]        w_df_kp1;
   `KEEP wire [`W_DF_DOT_RANGE]    w_df_dot_kp1;
   fll fll0(.clk(clk),
            .reset(reset),
            .start(loop_start_status[1]),
            .tag(`CHANNEL_ID_WIDTH'd0),
            .starting(fll_starting),
            .iq_prompt_k(iq_prompt_k),
            .iq_prompt_km1(iq_prompt_km1_0),
            .i_prompt_k(i_prompt_k_0),
            .q_prompt_k(q_prompt_k_0),
            .i_prompt_km1(i_prompt_km1_0),
            .q_prompt_km1(q_prompt_km1_0),
            .w_df_k(w_df_k_0),
            .w_df_dot_k(w_df_dot_k_0),
            .result_ready(fll_result_ready),
            .result_tag(fll_result_tag),
            .doppler_inc_kp1(doppler_inc_kp1),
            .w_df_kp1(w_df_kp1),
            .w_df_dot_kp1(w_df_dot_kp1));

   //Delay-locked loop.
   `KEEP wire                     dll_result_ready;
   `KEEP wire [`CHANNEL_ID_RANGE] dll_result_tag;
   `KEEP wire [`DLL_DPHI_RANGE]   dll_dphi_kp1;
   wire [`DLL_TAU_RANGE]          tau_prime_kp1;
   wire                           w_df_ready;
   wire [`W_DF_RANGE]             w_df_kp1_to_dll;
   dll dll0(.clk(clk),
            .reset(reset),
            .start(loop_start_status[0]),
            .tag(`CHANNEL_ID_WIDTH'd0),
            .starting(dll_starting),
            .iq_early(iq_early_k),
            .iq_late(iq_late_k),
            .w_df_ready(w_df_ready),
            .w_df_kp1(w_df_kp1_to_dll),
            .result_ready(dll_result_ready),
            .result_tag(dll_result_tag),
            .ca_dphi(dll_dphi_kp1),
            .tau_prime(tau_prime_kp1));

   //Sign-extend DLL phase increment to CA increment width.
   //FIXME Remove this and resize ca_dphi in DLL.
   wire [`CA_PHASE_INC_RANGE] ca_dphi_kp1;
   assign ca_dphi_kp1 = {{(`CA_PHASE_INC_WIDTH-`DLL_DPHI_WIDTH){dll_dphi_kp1[`DLL_DPHI_WIDTH-1]}},dll_dphi_kp1};

   ////////////////////
   // Report Results
   ////////////////////

   //Store channel 0 results.
   //FIXME Update everything for multi-channel.
   `PRESERVE reg [1:0] channel_0_loop_status;
   always @(posedge clk) begin
      //Flag each loop's completion for one cycle.
      channel_0_loop_status <= reset ? 2'h0 :
                               tracking_ready_0 ? 2'h0 :
                               fll_result_ready ? channel_0_loop_status | 2'b10 :
                               dll_result_ready ? channel_0_loop_status | 2'b01 :
                               channel_0_loop_status;
      
      //Store prompt IQ value to return to channel history.
      iq_prompt_k_0 <= iq_values_ready ? iq_prompt_k_value : iq_prompt_k_0;
      
      //Flag tracking complete for one cycle
      //as soon as all tracking loops finish.
      tracking_ready_0 <= channel_0_loop_status==2'b11 && !tracking_ready_0;

      //FLL results.
      if(fll_result_ready) begin
         doppler_inc_kp1_0 <= doppler_inc_kp1;
         w_df_kp1_0 <= w_df_kp1;
         w_df_dot_kp1_0 <= w_df_dot_kp1;
      end

      //FLL results.
      if(dll_result_ready) begin
         ca_dphi_kp1_0 <= ca_dphi_kp1;
         tau_prime_kp1_0 <= tau_prime_kp1;
      end
   end // always @ (posedge clk)

   assign w_df_ready = channel_0_loop_status[1];
   assign w_df_kp1_to_dll = w_df_kp1_0;
   
endmodule