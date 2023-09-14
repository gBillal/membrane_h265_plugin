defmodule Membrane.H265.Parser.NALuParser do
  @moduledoc """
  A module providing functionality of parsing a stream of binaries, out of which each
  is a payload of a single NAL unit.
  """
  alias Membrane.H265.Parser
  alias Membrane.H265.Parser.{NALu, NALuTypes}
  alias Membrane.H265.Parser.NALuParser.{SchemeParser, Schemes}

  @annexb_prefix_code <<0, 0, 0, 1>>

  @typedoc """
  A structure holding the state of the NALu parser.
  """
  @opaque t :: %__MODULE__{
            scheme_parser_state: SchemeParser.t(),
            input_stream_structure: Parser.stream_structure()
          }

  @enforce_keys [:input_stream_structure]
  defstruct @enforce_keys ++ [scheme_parser_state: SchemeParser.new()]

  @doc """
  Returns a structure holding a clear NALu parser state. `input_stream_structure`
  determines the prefixes of input NALU payloads.
  """
  @spec new(Parser.stream_structure()) :: t()
  def new(input_stream_structure \\ :annexb) do
    %__MODULE__{input_stream_structure: input_stream_structure}
  end

  @doc """
  Parses a list of binaries, each representing a single NALu.

  See `parse/3` for details.
  """
  @spec parse_nalus([binary()], NALu.timestamps(), boolean(), t()) :: {[NALu.t()], t()}
  def parse_nalus(nalus_payloads, timestamps \\ {nil, nil}, payload_prefixed? \\ true, state) do
    Enum.map_reduce(nalus_payloads, state, fn nalu_payload, state ->
      parse(nalu_payload, timestamps, payload_prefixed?, state)
    end)
  end

  @doc """
  Parses a binary representing a single NALu.

  Returns a structure that
  contains parsed fields fetched from that NALu.
  The input binary is expected to contain the prefix, defined as in
  the *"Annex B"* of the *"ITU-T Rec. H.265 (08/2021)"*.
  """
  @spec parse(binary(), NALu.timestamps(), boolean(), t()) :: {NALu.t(), t()}
  def parse(nalu_payload, timestamps \\ {nil, nil}, payload_prefixed? \\ true, state) do
    {prefix, unprefixed_nalu_payload} =
      if payload_prefixed? do
        unprefix_nalu_payload(nalu_payload, state.input_stream_structure)
      else
        {<<>>, nalu_payload}
      end

    <<nalu_header::binary-size(2), nalu_body::binary>> = unprefixed_nalu_payload

    new_scheme_parser_state = SchemeParser.new(state.scheme_parser_state)

    {parsed_fields, scheme_parser_state} =
      SchemeParser.parse_with_scheme(
        nalu_header,
        Schemes.NALuHeader,
        new_scheme_parser_state
      )

    type = NALuTypes.get_type(parsed_fields.nal_unit_type)

    {parsed_fields, scheme_parser_state} =
      parse_proper_nalu_type(nalu_body, scheme_parser_state, type)

    # Mark nalu as invalid if there's no parameter sets
    nalu_status =
      if type in NALuTypes.vcl_nalu_types() and
           not Map.has_key?(parsed_fields, :separate_colour_plane_flag),
         do: :error,
         else: :valid

    nalu =
      %NALu{
        parsed_fields: parsed_fields,
        type: type,
        status: nalu_status,
        stripped_prefix: prefix,
        payload: unprefixed_nalu_payload,
        timestamps: timestamps
      }

    state = %{state | scheme_parser_state: scheme_parser_state}

    {nalu, state}
  end

  @doc """
  Returns payload of the NALu with appropriate prefix generated based on output stream
  structure and prefix length.
  """
  @spec get_prefixed_nalu_payload(NALu.t(), Parser.stream_structure(), boolean()) :: binary()
  def get_prefixed_nalu_payload(nalu, output_stream_structure, stable_prefixing? \\ true) do
    case {output_stream_structure, stable_prefixing?} do
      {:annexb, true} ->
        case nalu.stripped_prefix do
          <<0, 0, 1>> -> <<0, 0, 1, nalu.payload::binary>>
          <<0, 0, 0, 1>> -> <<0, 0, 0, 1, nalu.payload::binary>>
          _prefix -> @annexb_prefix_code <> nalu.payload
        end

      {:annexb, false} ->
        @annexb_prefix_code <> nalu.payload

      {{_hevc, nalu_length_size}, _stable_prefixing?} ->
        <<byte_size(nalu.payload)::integer-size(nalu_length_size)-unit(8), nalu.payload::binary>>
    end
  end

  @spec unprefix_nalu_payload(binary(), Parser.stream_structure()) ::
          {stripped_prefix :: binary(), payload :: binary()}
  defp unprefix_nalu_payload(nalu_payload, :annexb) do
    case nalu_payload do
      <<0, 0, 1, rest::binary>> -> {<<0, 0, 1>>, rest}
      <<0, 0, 0, 1, rest::binary>> -> {<<0, 0, 0, 1>>, rest}
    end
  end

  defp unprefix_nalu_payload(nalu_payload, {_hevc, nalu_length_size}) do
    <<nalu_length::integer-size(nalu_length_size)-unit(8), rest::binary>> = nalu_payload

    {<<nalu_length::integer-size(nalu_length_size)-unit(8)>>, rest}
  end

  @spec prefix_nalus_payloads([binary()], Parser.stream_structure()) :: binary()
  def prefix_nalus_payloads(nalus, :annexb) do
    Enum.join([<<>> | nalus], @annexb_prefix_code)
  end

  def prefix_nalus_payloads(nalus, {_hevc, nalu_length_size}) do
    Enum.map_join(nalus, fn nalu ->
      <<byte_size(nalu)::integer-size(nalu_length_size)-unit(8), nalu::binary>>
    end)
  end

  defp parse_proper_nalu_type(payload, state, type) do
    # delete prevention emulation 3 bytes
    payload = :binary.split(payload, <<0, 0, 3>>, [:global]) |> Enum.join(<<0, 0>>)

    case type do
      :vps ->
        SchemeParser.parse_with_scheme(payload, Schemes.VPS, state)

      :sps ->
        SchemeParser.parse_with_scheme(payload, Schemes.SPS, state)

      :pps ->
        SchemeParser.parse_with_scheme(payload, Schemes.PPS, state)

      type ->
        if type in NALuTypes.vcl_nalu_types() do
          SchemeParser.parse_with_scheme(payload, Schemes.Slice, state)
        else
          {SchemeParser.get_local_state(state), state}
        end
    end
  end
end
