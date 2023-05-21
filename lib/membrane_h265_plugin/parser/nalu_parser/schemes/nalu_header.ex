defmodule Membrane.H265.Parser.NALuParser.Schemes.NALuHeader do
  @moduledoc false
  @behaviour Membrane.H265.Parser.NALuParser.Scheme

  @impl true
  def defaults(), do: []

  @impl true
  def scheme(),
    do: [
      field: {:forbidden_zero_bit, :u1},
      field: {:nal_unit_type, :u6},
      field: {:nuh_layer_id, :u6},
      field: {:nuh_temporal_id_plus1, :u3}
    ]
end
