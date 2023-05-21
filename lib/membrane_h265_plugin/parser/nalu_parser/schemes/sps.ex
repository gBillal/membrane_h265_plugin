defmodule Membrane.H265.Parser.NALuParser.Schemes.SPS do
  @moduledoc false

  @behaviour Membrane.H265.Parser.NALuParser.Scheme

  import Bitwise

  alias Membrane.H265
  alias Membrane.H265.Parser.NALuParser.Schemes.Common

  @impl true
  def defaults(), do: [chroma_format_idc: 1, separate_colour_plane_flag: 0]

  @impl true
  def scheme(),
    do:
      [
        field: {:video_parameter_set_id, :u4},
        field: {:max_sub_layers_minus1, :u3},
        field: {:temporal_id_nesting_flag, :u1}
      ] ++
        Common.profile_tier_level() ++
        [
          field: {:seq_parameter_set_id, :ue},
          field: {:chroma_format_idc, :ue},
          if: {
            {&(&1 == 3), [:chroma_format_idc]},
            field: {:separate_colour_plane_flag, :u1}
          },
          field: {:pic_width_in_luma_samples, :ue},
          field: {:pic_height_in_luma_samples, :ue},
          field: {:conformance_window_flag, :u1},
          if: {
            {&(&1 == 1), [:conformance_window_flag]},
            field: {:conf_win_left_offset, :ue},
            field: {:conf_win_right_offset, :ue},
            field: {:conf_win_top_offset, :ue},
            field: {:conf_win_bottom_offset, :ue}
          },
          field: {:bit_depth_luma_minus8, :ue},
          field: {:bit_depth_chroma_minus8, :ue},
          field: {:log2_max_pic_order_cnt_lsb_minus4, :ue},
          field: {:sub_layer_ordering_info_present_flag, :u1},
          for: {
            [
              iterator: :i,
              from:
                {&if(&1 == 1, do: 0, else: &2),
                 [:sub_layer_ordering_info_present_flag, :max_sub_layers_minus1]},
              to: {& &1, [:max_sub_layers_minus1]}
            ],
            field: {:max_dec_pic_buffering_minus1, :ue},
            field: {:max_num_reorder_pics, :ue},
            field: {:sps_max_latency_increase_plus1, :ue}
          },
          field: {:log2_min_luma_coding_block_size_minus3, :ue},
          field: {:log2_diff_max_min_luma_coding_block_size, :ue},
          field: {:log2_min_luma_transform_block_size_minus2, :ue},
          field: {:log2_diff_max_min_luma_transform_block_size, :ue},
          field: {:max_transform_hierarchy_depth_inter, :ue},
          field: {:max_transform_hierarchy_depth_intra, :ue},
          field: {:scaling_list_enabled_flag, :u1},
          if: {
            {&(&1 == 1), [:scaling_list_enabled_flag]},
            field: {:scaling_list_data_present_flag, :u1},
            if: {
              {&(&1 == 1), [:scaling_list_data_present_flag]},
              execute: &scaling_list(&1, &2, &3)
            }
          },
          field: {:amp_enabled_flag, :u1},
          field: {:sample_adaptive_offset_enabled_flag, :u1},
          field: {:pcm_enabled_flag, :u1},
          if: {
            {&(&1 == 1), [:pcm_enabled_flag]},
            field: {:pcm_sample_bit_depth_luma_minus1, :u4},
            field: {:pcm_sample_bit_depth_chroma_minus1, :u4},
            field: {:log2_min_pcm_luma_coding_block_size_minus3, :ue},
            field: {:log2_diff_max_min_pcm_luma_coding_block_size, :ue},
            field: {:pcm_loop_filter_disabled_flag, :u1}
          },
          field: {:num_short_term_ref_pic_sets, :ue},
          for: {
            [iterator: :i, from: 0, to: {&(&1 - 1), [:num_short_term_ref_pic_sets]}],
            st_ref_pic_set()
          },
          field: {:long_term_ref_pics_present_flag, :u1},
          if: {
            {&(&1 == 1), [:long_term_ref_pics_present_flag]},
            field: {:num_long_term_ref_pics_sps, :ue},
            for: {
              [iterator: :j, from: 0, to: {&(&1 - 1), [:num_long_term_ref_pics_sps]}],
              field: {:lt_ref_pic_poc_lsb_sps, :uv}, field: {:used_by_curr_pic_lt_sps_flag, :u1}
            }
          },
          field: {:temporal_mvp_enabled_flag, :u1},
          field: {:strong_intra_smoothing_enabled_flag, :u1},
          field: {:vui_parameters_present_flag, :u1},
          if: {
            {&(&1 == 1), [:vui_parameters_present_flag]},
            vui_parameters()
          },
          execute: &load_timing_info_from_vps/3,
          save_state_as_global_state: {&{:sps, &1}, [:seq_parameter_set_id]}
        ]

  defp scaling_list(payload, state, _iterators) do
    0..3
    |> Enum.reduce({payload, state}, fn i, {payload, state} ->
      read_scaling_list(payload, state, i)
    end)
  end

  defp read_scaling_list(payload, state, idx) do
    range = if idx == 3, do: 0..5//3, else: 0..5

    Enum.reduce(range, {payload, state, 8}, fn i, {payload, state, next_coeff} ->
      do_calculate_scaling_list(payload, state, next_coeff, i)
    end)
  end

  defp do_calculate_scaling_list(payload, state, next_coeff, idx) do
    <<pred_mode_flag::1, payload::binary>> = payload

    if pred_mode_flag == 0 do
      {_, payload} = H265.Common.ExpGolombConverter.to_integer(payload)
      {payload, state, next_coeff}
    else
      coef_num = min(64, 1 <<< (4 + (idx <<< 1)))

      {payload, next_coeff} =
        if idx > 1 do
          {scaling_list_coeff, payload} =
            H265.Common.ExpGolombConverter.to_integer(payload, negatives: false)

          next_coeff = scaling_list_coeff + 8

          {payload, next_coeff}
        else
          {payload, next_coeff}
        end

      Enum.reduce(0..coef_num, {payload, state, next_coeff}, fn _i,
                                                                {payload, state, next_coeff} ->
        {delta_coeff, payload} =
          H265.Common.ExpGolombConverter.to_integer(payload, negatives: false)

        next_coeff = rem(next_coeff + delta_coeff + 256, 256)

        {payload, state, next_coeff}
      end)
    end
  end

  defp st_ref_pic_set() do
    [
      if: {
        {&(&1 != 0), [:i]},
        field: {:inter_ref_pic_set_prediction_flag, :u1}
      },
      if: {
        {& &1[&2], [:inter_ref_pic_set_prediction_flag, :i]},
        if: {
          {&(&1 == &2), [:num_short_term_ref_pic_sets, :i]},
          field: {:delta_idx_minus1, :ue}
        },
        field: {:delta_rps_sign, :u1},
        field: {:abs_delta_rps_minus1, :u1},
        for: {
          [
            iterator: :j,
            from: 0,
            to:
              {&(&1[&3 - (&4[&3] + 1)] + &2[&3 - (&4[&3] + 1)]),
               [:num_negative_pics, :num_positive_pics, :i, :delta_idx_minus1]}
          ],
          field: {:used_by_curr_pic_flag, :u1},
          if: {
            {&(&1[&2][&3] == 0), [:used_by_curr_pic_flag, :i, :j]},
            field: {:use_delta_flag, :u1}
          }
        }
      },
      if: {
        {&(&1[&2] == 0), [:inter_ref_pic_set_prediction_flag, :i]},
        field: {:num_negative_pics, :ue},
        field: {:num_positive_pics, :ue},
        for: {
          [iterator: :j, from: 0, to: {&(&1 - 1), [:num_negative_pics]}],
          field: {:delta_poc_s0_minus1, :ue}, field: {:used_by_curr_pic_s0_flag, :u1}
        },
        for: {
          [iterator: :j, from: 0, to: {&(&1 - 1), [:num_positive_pics]}],
          field: {:delta_poc_s1_minus1, :ue}, field: {:used_by_curr_pic_s1_flag, :u1}
        }
      }
    ]
  end

  defp vui_parameters() do
    [
      field: {:aspect_ratio_info_present_flag, :u1},
      if: {
        {&(&1 == 1), [:aspect_ratio_info_present_flag]},
        field: {:aspect_ratio_idc, :u8},
        if: {
          {&(&1 == 255), [:aspect_ratio_idc]},
          field: {:sar_width, :u16}, field: {:sar_height, :u16}
        }
      },
      field: {:overscan_info_present_flag, :u1},
      if: {
        {&(&1 == 1), [:overscan_info_present_flag]},
        field: {:overscan_appropriate_flag, :u1}
      },
      field: {:video_signal_type_present_flag, :u1},
      if: {
        {&(&1 == 1), [:video_signal_type_present_flag]},
        field: {:video_format, :u3},
        field: {:video_full_range_flag, :u1},
        field: {:colour_description_present_flag, :u1},
        if: {
          {&(&1 == 1), [:colour_description_present_flag]},
          field: {:colour_primaries, :u8},
          field: {:transfer_characteristics, :u8},
          field: {:matrix_coeffs, :u8}
        }
      },
      field: {:chroma_loc_info_present_flag, :u1},
      if: {
        {&(&1 == 1), [:chroma_loc_info_present_flag]},
        field: {:chroma_sample_loc_type_top_field, :ue}, field: {:matrix_coeffs, :u8}
      },
      field: {:neutral_chroma_indication_flag, :u1},
      field: {:field_seq_flag, :u1},
      field: {:frame_field_info_present_flag, :u1},
      field: {:default_display_window_flag, :u1},
      if: {
        {&(&1 == 1), [:default_display_window_flag]},
        field: {:def_disp_win_left_offset, :ue},
        field: {:def_disp_win_right_offset, :ue},
        field: {:def_disp_win_top_offset, :ue},
        field: {:def_disp_win_bottom_offset, :ue}
      },
      field: {:vui_timing_info_present_flag, :u1},
      if: {
        {&(&1 == 1), [:vui_timing_info_present_flag]},
        field: {:num_units_in_tick, :u32},
        field: {:time_scale, :u32},
        field: {:poc_proportional_to_timing_flag, :u1},
        if: {
          {&(&1 == 1), [:poc_proportional_to_timing_flag]},
          field: {:num_ticks_poc_diff_one_minus1, :ue}
        },
        field: {:hrd_parameters_present_flag, :u1}
      }
    ]
  end

  defp load_timing_info_from_vps(payload, state, _iterators) do
    with false <- Map.get(state.__local__, :vui_timing_info_present_flag, false),
         vps_id <- Map.get(state.__local__, :video_parameter_set_id),
         vps when vps != nil <- Map.get(state.__global__, {:vps, vps_id}),
         true <- Map.get(vps, :timing_info_present_flag, false) do
      state =
        Map.merge(state, %{
          num_units_in_tick: vps.num_units_in_tick,
          time_scale: vps.time_scale,
          vui_timing_info_present_flag: 1
        })

      {payload, state}
    else
      _ -> {payload, state}
    end
  end
end
