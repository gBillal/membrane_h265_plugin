defmodule Membrane.H265.Parser.Format do
  @moduledoc """
  Module providing functionalities for preparing H265
  format based on the parsed VPS and SPS NAL units.
  """

  alias Membrane.H265

  @profiles_description [
    main: [profile_idc: 1],
    main_10: [profile_idc: 2],
    main_still_picture: [profile_idc: 3],
    rext: [profile_idc: 4]
  ]

  @doc """
  Prepares the `Membrane.H265.t()` format based on the parsed SPS NALu.
  During the process, the function determines the profile of
  the h265 stream and the picture resolution.
  """
  @spec from_sps(
          sps_nalu :: H265.Parser.NALu.t(),
          options_fields :: [
            framerate: {pos_integer(), pos_integer()},
            output_alignment: :au | :nalu
          ]
        ) :: H265.t()
  def from_sps(sps_nalu, options_fields) do
    sps = sps_nalu.parsed_fields

    {sub_width_c, sub_height_c} =
      case sps.chroma_format_idc do
        0 -> {1, 1}
        1 -> {2, 2}
        2 -> {2, 1}
        3 -> {1, 1}
        _other -> {nil, nil}
      end

    {width, height} =
      if sps.conformance_window_flag == 1 do
        {sps.pic_width_in_luma_samples -
           sub_width_c * (sps.conf_win_right_offset + sps.conf_win_left_offset),
         sps.pic_height_in_luma_samples -
           sub_height_c * (sps.conf_win_bottom_offset + sps.conf_win_top_offset)}
      else
        {sps.pic_width_in_luma_samples, sps.pic_height_in_luma_samples}
      end

    profile = parse_profile(sps_nalu)

    %H265{
      width: width,
      height: height,
      profile: profile,
      framerate: Keyword.get(options_fields, :framerate),
      alignment: Keyword.get(options_fields, :output_alignment),
      nalu_in_metadata?: true
    }
  end

  defp parse_profile(sps_nalu) do
    fields = sps_nalu.parsed_fields

    {profile_name, _constraints_list} =
      Enum.find(@profiles_description, {nil, nil}, fn {_profile_name, constraints_list} ->
        Enum.all?(constraints_list, fn {key, value} ->
          Map.has_key?(fields, key) and fields[key] == value
        end)
      end)

    if profile_name == nil, do: raise("Cannot read the profile name based on SPS's fields.")
    profile_name
  end
end
