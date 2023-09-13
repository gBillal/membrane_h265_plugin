defmodule Membrane.H265.Parser.NALuSplitter do
  @moduledoc """
  A module with functions responsible for splitting
  the h265 stream into the NAL units.

  The splitting is based on
  *"Annex B"* of the *"ITU-T Rec. H.265 (08/2021)"*.
  """

  @typedoc """
  A structure holding the state of the NALu splitter.
  """
  @opaque t :: %__MODULE__{
            input_stream_structure: Membrane.H265.Parser.stream_structure(),
            unparsed_payload: binary()
          }

  @enforce_keys [:input_stream_structure]
  defstruct @enforce_keys ++ [unparsed_payload: <<>>]

  @doc """
  Returns a structure holding a NALu splitter state.

  By default, the inner `unparsed_payload` of the state is clean.
  However, there is a possibility to set that `unparsed_payload`
  to a given binary, provided as an argument of the `new/1` function.
  """
  @spec new(Membrane.H265.Parser.stream_structure(), binary()) :: t()
  def new(input_stream_structure \\ :annexb, intial_binary \\ <<>>) do
    %__MODULE__{input_stream_structure: input_stream_structure, unparsed_payload: intial_binary}
  end

  @doc """
  Splits the binary into NALus sequence.

  Takes a binary h265 stream as an input
  and produces a list of binaries, where each binary is
  a complete NALu that can be passed to the `Membrane.H265.Parser.NALuParser.parse/2`.
  """
  @spec split(payload :: binary(), assume_nalu_aligned :: boolean, state :: t()) ::
          {[binary()], t()}
  def split(payload, assume_nalu_aligned \\ false, state) do
    total_payload = state.unparsed_payload <> payload

    nalus_payloads_list = get_complete_nalus_list(total_payload, state.input_stream_structure)

    total_nalus_payloads_size = IO.iodata_length(nalus_payloads_list)

    unparsed_payload =
      :binary.part(
        total_payload,
        total_nalus_payloads_size,
        byte_size(total_payload) - total_nalus_payloads_size
      )

    cond do
      unparsed_payload == <<>> ->
        {nalus_payloads_list, %{state | unparsed_payload: <<>>}}

      assume_nalu_aligned ->
        {nalus_payloads_list ++ [unparsed_payload], %{state | unparsed_payload: <<>>}}

      true ->
        {nalus_payloads_list, %{state | unparsed_payload: unparsed_payload}}
    end
  end

  defp get_complete_nalus_list(payload, :annexb) do
    payload
    |> :binary.matches([<<0, 0, 0, 1>>, <<0, 0, 1>>])
    |> Enum.chunk_every(2, 1, [{byte_size(payload), nil}])
    |> then(&Enum.drop(&1, -1))
    |> Enum.map(fn [{from, _prefix_len}, {to, _}] ->
      len = to - from
      :binary.part(payload, from, len)
    end)
  end

  defp get_complete_nalus_list(payload, {_hevc, nalu_length_size})
       when byte_size(payload) < nalu_length_size do
    []
  end

  defp get_complete_nalus_list(payload, {hevc, nalu_length_size}) do
    <<nalu_length::integer-size(nalu_length_size)-unit(8), rest::binary>> = payload

    if nalu_length > byte_size(rest) do
      []
    else
      <<nalu::binary-size(nalu_length + nalu_length_size), rest::binary>> = payload
      [nalu | get_complete_nalus_list(rest, {hevc, nalu_length_size})]
    end
  end
end
