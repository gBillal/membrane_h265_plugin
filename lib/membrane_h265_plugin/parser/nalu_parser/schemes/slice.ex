defmodule Membrane.H265.Parser.NALuParser.Schemes.Slice do
  @moduledoc false
  @behaviour Membrane.H265.Parser.NALuParser.Scheme

  @impl true
  def defaults(), do: []

  @impl true
  def scheme(),
    do: [
      field: {:first_slice_segment_in_pic_flag, :u1},
      if: {
        {&(&1 >= 16 and &1 <= 23), [:nal_unit_type]},
        field: {:no_output_of_prior_pics_flag, :u1}
      },
      field: {:pic_parameter_set_id, :ue},
      execute: &load_data_from_sps(&1, &2, &3)
    ]

  defp load_data_from_sps(payload, state, _iterators) do
    with pic_parameter_set_id when pic_parameter_set_id != nil <-
           Map.get(state.__local__, :pic_parameter_set_id),
         pps when pps != nil <- Map.get(state.__global__, {:pps, pic_parameter_set_id}),
         seq_parameter_set_id when seq_parameter_set_id != nil <-
           Map.get(pps, :seq_parameter_set_id),
         sps <- Map.get(state.__global__, {:sps, seq_parameter_set_id}) do
      state =
        Bunch.Access.put_in(
          state,
          [:__local__, :separate_colour_plane_flag],
          Map.get(sps, :separate_colour_plane_flag, 0)
        )

      sps_fields = Map.take(sps, [:log2_max_pic_order_cnt_lsb_minus4])

      state = Map.update(state, :__local__, %{}, &Map.merge(&1, sps_fields))

      {payload, state}
    else
      _error -> {payload, state}
    end
  end
end
