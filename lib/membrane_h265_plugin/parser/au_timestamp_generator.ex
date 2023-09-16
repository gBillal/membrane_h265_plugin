defmodule Membrane.H265.Parser.AUTimestampGenerator do
  @moduledoc false

  require Membrane.H265.Parser.NALuTypes, as: NALuTypes

  alias Membrane.H265.Parser.NALu

  @type framerate :: {frames :: pos_integer(), seconds :: pos_integer()}

  @type t :: %{
          framerate: framerate,
          max_frame_reorder: 0..15,
          au_counter: non_neg_integer(),
          key_frame_au_idx: non_neg_integer(),
          prev_pic_order_cnt_lsb: integer(),
          prev_pic_order_cnt_msb: integer()
        }

  @spec new(config :: %{:framerate => framerate, optional(:add_dts_offset) => boolean()}) :: t
  def new(config) do
    # To make sure that PTS >= DTS at all times, we take maximal possible
    # frame reorder (which is 15 according to the spec) and subtract
    # `max_frame_reorder * frame_duration` from each frame's DTS.
    # This behaviour can be disabled by setting `add_dts_offset: false`.
    max_frame_reorder = if Map.get(config, :add_dts_offset, true), do: 15, else: 0

    %{
      framerate: config.framerate,
      max_frame_reorder: max_frame_reorder,
      au_counter: 0,
      key_frame_au_idx: 0,
      prev_pic_order_cnt_lsb: 0,
      prev_pic_order_cnt_msb: 0
    }
  end

  @spec generate_ts_with_constant_framerate([NALu.t()], t) ::
          {{pts :: non_neg_integer(), dts :: non_neg_integer()}, t}
  def generate_ts_with_constant_framerate(au, state) do
    %{
      au_counter: au_counter,
      key_frame_au_idx: key_frame_au_idx,
      max_frame_reorder: max_frame_reorder,
      framerate: {frames, seconds}
    } = state

    first_vcl_nalu = Enum.find(au, &(&1.type in NALuTypes.vcl_nalu_types()))
    {poc, state} = calculate_poc(first_vcl_nalu, state)

    key_frame_au_idx = if poc == 0, do: au_counter, else: key_frame_au_idx
    pts = div((key_frame_au_idx + poc) * seconds * Membrane.Time.second(), frames)
    dts = div((au_counter - max_frame_reorder) * seconds * Membrane.Time.second(), frames)

    state = %{
      state
      | au_counter: au_counter + 1,
        key_frame_au_idx: key_frame_au_idx
    }

    {{pts, dts}, state}
  end

  # Calculate picture order count according to section 8.3.1 of the ITU-T H265 specification
  defp calculate_poc(vcl_nalu, state) do
    max_pic_order_cnt_lsb = 2 ** (vcl_nalu.parsed_fields.log2_max_pic_order_cnt_lsb_minus4 + 4)

    # We exclude CRA pictures from IRAP pictures since we have no way
    # to assert the value of the flag NoRaslOutputFlag.
    # If the CRA is the first access unit in the bytestream, the flag would be
    # equal to 1 which reset the POC counter, and that condition is
    # satisfied here since the initial value for prev_pic_order_cnt_msb and
    # prev_pic_order_cnt_lsb are 0
    {prev_pic_order_cnt_msb, prev_pic_order_cnt_lsb} =
      if vcl_nalu.parsed_fields.nal_unit_type in 16..20 do
        {0, 0}
      else
        {state.prev_pic_order_cnt_msb, state.prev_pic_order_cnt_lsb}
      end

    pic_order_cnt_lsb = vcl_nalu.parsed_fields.pic_order_cnt_lsb

    pic_order_cnt_msb =
      cond do
        pic_order_cnt_lsb < prev_pic_order_cnt_lsb and
            prev_pic_order_cnt_lsb - pic_order_cnt_lsb >= div(max_pic_order_cnt_lsb, 2) ->
          prev_pic_order_cnt_msb + max_pic_order_cnt_lsb

        pic_order_cnt_lsb > prev_pic_order_cnt_lsb and
            pic_order_cnt_lsb - prev_pic_order_cnt_lsb > div(max_pic_order_cnt_lsb, 2) ->
          prev_pic_order_cnt_msb - max_pic_order_cnt_lsb

        true ->
          prev_pic_order_cnt_msb
      end

    {prev_pic_order_cnt_lsb, prev_pic_order_cnt_msb} =
      if vcl_nalu.type in [:radl_r, :radl_n, :rasl_r, :rasl_n] or
           vcl_nalu.parsed_fields.nal_unit_type in 0..15//2 do
        {prev_pic_order_cnt_lsb, prev_pic_order_cnt_msb}
      else
        {pic_order_cnt_lsb, pic_order_cnt_msb}
      end

    {pic_order_cnt_msb + pic_order_cnt_lsb,
     %{
       state
       | prev_pic_order_cnt_lsb: prev_pic_order_cnt_lsb,
         prev_pic_order_cnt_msb: prev_pic_order_cnt_msb
     }}
  end
end
