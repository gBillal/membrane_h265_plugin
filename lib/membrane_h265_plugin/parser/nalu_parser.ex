defmodule Membrane.H265.Parser.NALuParser do
  @moduledoc """
  A module providing functionality of parsing a stream of binaries, out of which each
  is a payload of a single NAL unit.
  """
  alias Membrane.H265.Parser.{NALu, NALuTypes}
  alias Membrane.H265.Parser.NALuParser.SchemeParser
  alias Membrane.H265.Parser.NALuParser.Schemes

  @non_vcl_nalus [:vps, :sps, :pps, :aud, :prefix_sei]

  @typedoc """
  A structure holding the state of the NALu parser.
  """
  @opaque t :: %__MODULE__{
            scheme_parser_state: SchemeParser.t(),
            has_seen_keyframe?: boolean()
          }

  defstruct scheme_parser_state: SchemeParser.new(), has_seen_keyframe?: false

  @doc """
  Returns a structure holding a clear NALu parser state.
  """
  @spec new() :: t()
  def new(), do: %__MODULE__{}

  @doc """
  Parses a binary representing a single NALu.

  Returns a structure that
  contains parsed fields fetched from that NALu.
  The input binary is expected to contain the prefix, defined as in
  the *"Annex B"* of the *"ITU-T Rec. H.265 (08/2021)"*.
  """
  @spec parse(binary(), t()) :: {NALu.t(), t()}
  def parse(nalu_payload, state) do
    {prefix_length, nalu_payload_without_prefix} =
      case nalu_payload do
        <<0, 0, 1, rest::binary>> -> {3, rest}
        <<0, 0, 0, 1, rest::binary>> -> {4, rest}
      end

    <<nalu_header::binary-size(2), nalu_body::binary>> = nalu_payload_without_prefix

    new_scheme_parser_state = SchemeParser.new(state.scheme_parser_state)

    {parsed_fields, scheme_parser_state} =
      SchemeParser.parse_with_scheme(
        nalu_header,
        Schemes.NALuHeader,
        new_scheme_parser_state
      )

    type = NALuTypes.get_type(parsed_fields.nal_unit_type)

    {nalu, scheme_parser_state, has_seen_keyframe?} =
      try do
        {parsed_fields, scheme_parser_state} =
          parse_proper_nalu_type(nalu_body, scheme_parser_state, type)

        has_seen_keyframe? =
          state.has_seen_keyframe? or Enum.member?(NALuTypes.irap_nalus(), type)

        {%NALu{
           parsed_fields: parsed_fields,
           type: type,
           status: nal_unit_status(type, state),
           prefix_length: prefix_length,
           payload: nalu_payload
         }, scheme_parser_state, has_seen_keyframe?}
      catch
        "Cannot load information from SPS" ->
          {%NALu{
             parsed_fields: parsed_fields,
             type: type,
             status: :error,
             prefix_length: prefix_length,
             payload: nalu_payload
           }, scheme_parser_state, state.has_seen_keyframe?}
      end

    state = %__MODULE__{
      scheme_parser_state: scheme_parser_state,
      has_seen_keyframe?: has_seen_keyframe?
    }

    {nalu, state}
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
          {%{}, state}
        end
    end
  end

  defp nal_unit_status(nalu_type, state) do
    nalus_to_check = Enum.concat(NALuTypes.irap_nalus(), @non_vcl_nalus)

    if Enum.member?(nalus_to_check, nalu_type) or state.has_seen_keyframe?,
      do: :valid,
      else: :error
  end
end
