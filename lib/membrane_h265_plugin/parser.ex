defmodule Membrane.H265.Parser do
  @moduledoc """
  Membrane element providing parser for H265 encoded video stream.

  The parser:
  * prepares and sends the appropriate stream format, based on information provided in the stream and via the element's options
  * splits the incoming stream into h265 access units - each buffer being output is a `Membrane.Buffer` struct with a
  binary payload of a single access unit
  * enriches the output buffers with the metadata describing the way the access unit is split into NAL units, type of each NAL unit
  making up the access unit and the information if the access unit hold a keyframe.

  The parser works in one of three possible modes, depending on the structure of the input buffers:
  * `:bytestream` - each input buffer contains some part of h265 stream's payload, but not necessary a logical
  h265 unit (like NAL unit or an access unit). Can be used for i.e. for parsing the stream read from the file.
  * `:nalu_aligned` - each input buffer contains a single NAL unit's payload
  * `:au_aligned` - each input buffer contains a single access unit's payload

  The parser's mode is set automatically, based on the input stream format received by that element:
  * Receiving `%Membrane.RemoteStream{type: :bytestream}` results in the parser mode being set to `:bytestream`
  * Receiving `%Membrane.H265{alignment: :nalu}` results in the parser mode being set to `:nalu_aligned`.
  * Receiving `%Membrane.H265{alignment: :au}` results in the parser mode being set to `:au_aligned`.

  The parser also allows for conversion between stream structures. The available structures are:
  * Annex B, `:annexb` - In a stream with this structure each NAL unit is prefixed by three or
  four-byte start code (`0x(00)000001`) that allows to identify boundaries between them.
  * hvc1, `:hvc1` - In such stream a DCR (Decoder Configuration Record) is included in `stream_format`
  and NALUs lack the start codes, but are prefixed with their length. The length of these prefixes
  is contained in the stream's DCR. PPSs, SPSs and VPSs (Picture Parameter Sets, Sequence Parameter Sets and Video Parameter Sets)
  are transported in the DCR.
  * hev1, `:hev1` - The same as hvc1, only that parameter sets may be also present in the stream (in-band).
  """

  use Membrane.Filter

  require Membrane.Logger

  alias __MODULE__.{
    AUSplitter,
    DecoderConfigurationRecord,
    Format,
    NALuParser,
    NALuSplitter,
    NALuTypes
  }

  alias Membrane.{Buffer, H265, RemoteStream}
  alias Membrane.Element.{Action, CallbackContext}

  @typedoc """
  Type referencing `Membrane.H265.stream_structure` type, in case of `:hvc1` and `:hev1`
  stream structure, it contains an information about the size of each NALU's prefix describing
  their length.
  """
  @type stream_structure :: :annexb | {:hvc1 | :hev1, nalu_length_size :: pos_integer()}

  @typep raw_stream_structure :: H265.stream_structure()
  @typep state :: Membrane.Element.state()
  @typep callback_return :: Membrane.Element.Base.callback_return()

  @nalu_length_size 4

  def_input_pad :input,
    demand_unit: :buffers,
    demand_mode: :auto,
    accepted_format: any_of(%RemoteStream{type: :bytestream}, H265)

  def_output_pad :output,
    demand_mode: :auto,
    accepted_format:
      %H265{alignment: alignment, nalu_in_metadata?: true} when alignment in [:au, :nalu]

  def_options vpss: [
                spec: [binary()],
                default: [],
                description: """
                Video Parameter Set NAL unit binary payloads - if absent in the stream, may
                be provided via this option (only available for `:annexb` output stream format)

                Any decoder conforming to the profiles specified in "Annex A" of ITU/IEC H265 (08/21),
                but does not support INBLD may discard all VPS NAL units.
                """
              ],
              spss: [
                spec: [binary()],
                default: [],
                description: """
                Sequence Parameter Set NAL unit binary payloads - if absent in the stream, should
                be provided via this option (only available for `:annexb` output stream format).
                """
              ],
              ppss: [
                spec: [binary()],
                default: [],
                description: """
                Picture Parameter Set NAL unit binary payloads - if absent in the stream, should
                be provided via this option (only available for `:annexb` output stream format).
                """
              ],
              framerate: [
                spec: {pos_integer(), pos_integer()} | nil,
                default: nil,
                description: """
                Framerate of the video, represented as a tuple consisting of a numerator and the
                denominator.
                Its value will be sent inside the output `Membrane.H265` stream format.
                """
              ],
              skip_until_keyframe: [
                spec: boolean(),
                default: true,
                description: """
                Determines whether to drop the stream until the first key frame is received.

                Defaults to true.
                """
              ],
              output_alignment: [
                spec: :au | :nalu,
                default: :au,
                description: """
                Alignment of the buffers produced as an output of the parser.
                If set to `:au`, each output buffer will be a single access unit.
                Otherwise, if set to `:nalu`, each output buffer will be a single NAL unit.
                """
              ],
              output_stream_structure: [
                spec:
                  nil
                  | :annexb
                  | :hvc1
                  | :hev1
                  | {:hvc1 | :hev1, nalu_length_size :: pos_integer()},
                default: nil,
                description: """
                format of the outgoing H265 stream, if set to `:annexb` NALUs will be separated by
                a start code (0x(00)000001) or if set to `:hvc1` or `:hev1` they will be prefixed by their size.
                Additionally for `:hvc1` and `:hev1` a tuple can be passed containing the atom and
                `nalu_length_size` that determines the size in bytes of each NALU's field
                describing their length (by default 4). In hvc1 output streams the PPSs, SPSs and VPSs will be
                transported in the DCR, when in hev1 they will be present only in the stream (in-band).
                If not provided or set to nil the stream's structure will remain unchanged.
                """
              ]

  @impl true
  def handle_init(_ctx, opts) do
    output_stream_structure =
      case opts.output_stream_structure do
        :hvc1 -> {:hvc1, @nalu_length_size}
        :hev1 -> {:hvc1, @nalu_length_size}
        stream_structure -> stream_structure
      end

    state = %{
      nalu_splitter: nil,
      nalu_parser: nil,
      au_splitter: AUSplitter.new(),
      mode: nil,
      profile: nil,
      previous_buffer_timestamps: {nil, nil},
      output_alignment: opts.output_alignment,
      framerate: opts.framerate,
      skip_until_keyframe: opts.skip_until_keyframe,
      frame_prefix: <<>>,
      cached_vpss: %{},
      cached_spss: %{},
      cached_ppss: %{},
      initial_vpss: opts.vpss,
      initial_spss: opts.spss,
      initial_ppss: opts.ppss,
      input_stream_structure: nil,
      output_stream_structure: output_stream_structure
    }

    {[], state}
  end

  @impl true
  def handle_stream_format(:input, stream_format, ctx, state) do
    {alignment, input_raw_stream_format} =
      case stream_format do
        %RemoteStream{type: :bytestream} ->
          {:bytestream, :annexb}

        %H265{alignment: alignment, stream_structure: stream_structure} ->
          {alignment, stream_structure}
      end

    is_first_received_stream_format = is_nil(ctx.pads.input.stream_format)

    mode = get_mode_from_alignment(alignment)

    input_stream_structure = parse_raw_stream_structure(input_raw_stream_format)

    state =
      cond do
        is_first_received_stream_format ->
          %{
            state
            | mode: mode,
              nalu_splitter: NALuSplitter.new(input_stream_structure),
              nalu_parser: NALuParser.new(input_stream_structure),
              input_stream_structure: input_stream_structure,
              output_stream_structure: state.output_stream_structure || input_stream_structure
          }

        not is_input_stream_structure_change_allowed?(
          input_stream_structure,
          state.input_stream_structure
        ) ->
          raise "stream structure cannot be fundamentally changed during stream"

        mode != state.mode ->
          raise "mode cannot be changed during stream"

        true ->
          state
      end

    {incoming_vpss, incoming_spss, incoming_ppss} =
      get_stream_format_parameter_sets(
        input_raw_stream_format,
        is_first_received_stream_format,
        state
      )

    process_stream_format_parameter_sets(incoming_vpss, incoming_spss, incoming_ppss, ctx, state)
  end

  @impl true
  def handle_process(:input, %Membrane.Buffer{} = buffer, ctx, state) do
    {payload, state} =
      case state.frame_prefix do
        <<>> -> {buffer.payload, state}
        prefix -> {prefix <> buffer.payload, %{state | frame_prefix: <<>>}}
      end

    is_nalu_aligned = state.mode != :bytestream

    {nalus_payloads, nalu_splitter} =
      NALuSplitter.split(payload, is_nalu_aligned, state.nalu_splitter)

    timestamps = if state.mode == :bytestream, do: {nil, nil}, else: {buffer.pts, buffer.dts}
    {nalus, nalu_parser} = NALuParser.parse_nalus(nalus_payloads, timestamps, state.nalu_parser)
    is_au_aligned = state.mode == :au_aligned
    {access_units, au_splitter} = AUSplitter.split(nalus, is_au_aligned, state.au_splitter)
    {access_units, state} = skip_improper_aus(access_units, state)
    {actions, state} = prepare_actions_for_aus(access_units, ctx, state)

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {actions, state}
  end

  @impl true
  def handle_end_of_stream(:input, ctx, state) when state.mode != :au_aligned do
    {last_nalu_payload, nalu_splitter} = NALuSplitter.split(<<>>, true, state.nalu_splitter)
    {last_nalu, nalu_parser} = NALuParser.parse_nalus(last_nalu_payload, state.nalu_parser)
    {maybe_improper_aus, au_splitter} = AUSplitter.split(last_nalu, true, state.au_splitter)
    {aus, state} = skip_improper_aus(maybe_improper_aus, state)
    {actions, state} = prepare_actions_for_aus(aus, ctx, state)

    actions = if stream_format_sent?(actions, ctx), do: actions, else: []

    state = %{
      state
      | nalu_splitter: nalu_splitter,
        nalu_parser: nalu_parser,
        au_splitter: au_splitter
    }

    {actions ++ [end_of_stream: :output], state}
  end

  @impl true
  def handle_end_of_stream(_pad, _ctx, state) do
    {[end_of_stream: :output], state}
  end

  @spec get_mode_from_alignment(:au | :nalu | :bytestream) ::
          :au_aligned | :nalu_aligned | :bytestream
  defp get_mode_from_alignment(alignment) do
    case alignment do
      :au -> :au_aligned
      :nalu -> :nalu_aligned
      :bytestream -> :bytestream
    end
  end

  @spec get_stream_format_parameter_sets(raw_stream_structure(), boolean(), state()) ::
          {[binary()], [binary()], [binary()]}
  defp get_stream_format_parameter_sets({_hevc, dcr}, _is_first_received_stream_format, state) do
    %{vpss: dcr_vpss, spss: dcr_spss, ppss: dcr_ppss} = DecoderConfigurationRecord.parse(dcr)

    new_uncached_vpss = dcr_vpss -- Enum.map(state.cached_vpss, fn {_id, ps} -> ps.payload end)
    new_uncached_spss = dcr_spss -- Enum.map(state.cached_spss, fn {_id, ps} -> ps.payload end)
    new_uncached_ppss = dcr_ppss -- Enum.map(state.cached_ppss, fn {_id, ps} -> ps.payload end)

    {new_uncached_vpss, new_uncached_spss, new_uncached_ppss}
  end

  defp get_stream_format_parameter_sets(:annexb, is_first_received_stream_format, state) do
    if is_first_received_stream_format,
      do: {state.initial_vpss, state.initial_spss, state.initial_ppss},
      else: {[], [], []}
  end

  @spec process_stream_format_parameter_sets(
          [binary()],
          [binary()],
          [binary()],
          CallbackContext.t(),
          state()
        ) ::
          {[Action.t()], state()}
  defp process_stream_format_parameter_sets(
         new_vpss,
         new_spss,
         new_ppss,
         ctx,
         %{output_stream_structure: {:hvc1, _}} = state
       ) do
    {parsed_new_uncached_vpss, nalu_parser} =
      NALuParser.parse_nalus(new_vpss, {nil, nil}, false, state.nalu_parser)

    {parsed_new_uncached_spss, nalu_parser} =
      NALuParser.parse_nalus(new_spss, {nil, nil}, false, nalu_parser)

    {parsed_new_uncached_ppss, nalu_parser} =
      NALuParser.parse_nalus(new_ppss, {nil, nil}, false, nalu_parser)

    state = %{state | nalu_parser: nalu_parser}

    process_new_parameter_sets(
      parsed_new_uncached_vpss,
      parsed_new_uncached_spss,
      parsed_new_uncached_ppss,
      ctx,
      state
    )
  end

  defp process_stream_format_parameter_sets(vpss, spss, ppss, _ctx, state) do
    frame_prefix =
      NALuParser.prefix_nalus_payloads(vpss ++ spss ++ ppss, state.input_stream_structure)

    {[], %{state | frame_prefix: frame_prefix}}
  end

  @spec process_new_parameter_sets(
          [NALu.t()],
          [NALu.t()],
          [NALu.t()],
          CallbackContext.t(),
          state()
        ) ::
          {[Action.t()], state()}
  defp process_new_parameter_sets(new_vpss, new_spss, new_ppss, context, state) do
    updated_cached_vpss =
      merge_parameter_sets(new_vpss, state.cached_vpss, :video_parameter_set_id)

    updated_cached_spss = merge_parameter_sets(new_spss, state.cached_spss, :seq_parameter_set_id)
    updated_cached_ppss = merge_parameter_sets(new_ppss, state.cached_ppss, :pic_parameter_set_id)

    state = %{
      state
      | cached_vpss: updated_cached_vpss,
        cached_spss: updated_cached_spss,
        cached_ppss: updated_cached_ppss
    }

    latest_sps = List.last(new_spss)

    last_sent_stream_format = context.pads.output.stream_format

    output_raw_stream_structure =
      case state.output_stream_structure do
        :annexb ->
          :annexb

        {hevc, _nalu_length_size} = output_stream_structure ->
          {hevc,
           DecoderConfigurationRecord.generate(
             Map.values(updated_cached_vpss),
             Map.values(updated_cached_spss),
             Map.values(updated_cached_ppss),
             output_stream_structure
           )}
      end

    stream_format_candidate =
      case {latest_sps, last_sent_stream_format} do
        {nil, nil} ->
          nil

        {nil, last_sent_stream_format} ->
          %{last_sent_stream_format | stream_structure: output_raw_stream_structure}

        {latest_sps, _last_sent_stream_format} ->
          Format.from_sps(latest_sps, output_raw_stream_structure,
            output_alignment: state.output_alignment,
            framerate: state.framerate
          )
      end

    if stream_format_candidate in [last_sent_stream_format, nil] do
      {[], state}
    else
      {
        [stream_format: {:output, stream_format_candidate}],
        %{state | profile: stream_format_candidate.profile}
      }
    end
  end

  @spec merge_parameter_sets([NALu.t()], %{non_neg_integer() => NALu.t()}, atom()) ::
          %{non_neg_integer() => NALu.t()}
  defp merge_parameter_sets(new_parameter_sets, cached_parameter_sets, id_key) do
    new_parameter_sets
    |> Enum.map(&{&1.parsed_fields[id_key], &1})
    |> Map.new()
    |> then(&Map.merge(cached_parameter_sets, &1))
  end

  @spec process_au_parameter_sets(AUSplitter.access_unit(), CallbackContext.t(), state()) ::
          {AUSplitter.access_unit(), [Action.t()], state()}
  defp process_au_parameter_sets(au, context, state) do
    au_vpss = Enum.filter(au, &(&1.type == :vps))
    au_spss = Enum.filter(au, &(&1.type == :sps))
    au_ppss = Enum.filter(au, &(&1.type == :pps))

    {stream_format_actions, state} =
      process_new_parameter_sets(au_vpss, au_spss, au_ppss, context, state)

    au =
      case state.output_stream_structure do
        {:hvc1, _nalu_length_size} ->
          remove_parameter_sets(au)

        _stream_structure ->
          delete_duplicate_parameter_sets(au)
      end

    {au, stream_format_actions, state}
  end

  @spec parse_raw_stream_structure(raw_stream_structure()) :: stream_structure()
  defp parse_raw_stream_structure(:annexb), do: :annexb

  defp parse_raw_stream_structure({hevc, dcr}) do
    %{nalu_length_size: nalu_length_size} = DecoderConfigurationRecord.parse(dcr)
    {hevc, nalu_length_size}
  end

  @spec is_input_stream_structure_change_allowed?(
          raw_stream_structure() | stream_structure(),
          raw_stream_structure() | stream_structure()
        ) :: boolean()
  defp is_input_stream_structure_change_allowed?(:annexb, :annexb), do: true
  defp is_input_stream_structure_change_allowed?({hevc, _}, {hevc, _}), do: true

  defp is_input_stream_structure_change_allowed?(_stream_structure1, _stream_structure2),
    do: false

  defp skip_improper_aus(aus, state) do
    Enum.flat_map_reduce(aus, state, fn au, state ->
      has_seen_keyframe? =
        Enum.all?(au, &(&1.status == :valid)) and
          Enum.any?(au, &(&1.type in NALuTypes.irap_nalus()))

      state = %{
        state
        | skip_until_keyframe: state.skip_until_keyframe and not has_seen_keyframe?
      }

      if Enum.any?(au, &(&1.status == :error)) or state.skip_until_keyframe do
        {[], state}
      else
        {[au], state}
      end
    end)
  end

  @spec prepare_actions_for_aus(
          [AUSplitter.access_unit()],
          CallbackContext.t(),
          state()
        ) :: callback_return()
  defp prepare_actions_for_aus(aus, ctx, state) do
    Enum.flat_map_reduce(aus, state, fn au, state ->
      {au, stream_format_actions, state} = process_au_parameter_sets(au, ctx, state)

      {pts, dts} = hd(au).timestamps

      buffers_actions = [
        buffer:
          {:output,
           wrap_into_buffer(au, pts, dts, state.output_alignment, state.output_stream_structure)}
      ]

      {stream_format_actions ++ buffers_actions, state}
    end)
  end

  @spec remove_parameter_sets(AUSplitter.access_unit()) :: AUSplitter.access_unit()
  defp remove_parameter_sets(au) do
    Enum.reject(au, &(&1.type in [:vps, :sps, :pps]))
  end

  @spec delete_duplicate_parameter_sets(AUSplitter.access_unit()) :: AUSplitter.access_unit()
  defp delete_duplicate_parameter_sets(au) do
    if idr_au?(au), do: Enum.uniq(au), else: au
  end

  @spec idr_au?(AUSplitter.access_unit()) :: boolean()
  defp idr_au?(au), do: Enum.any?(au, &(&1.type in NALuTypes.irap_nalus()))

  @spec wrap_into_buffer(
          AUSplitter.access_unit(),
          Membrane.Time.t(),
          Membrane.Time.t(),
          :au | :nalu,
          stream_structure()
        ) :: Buffer.t()
  defp wrap_into_buffer(access_unit, pts, dts, :au, output_stream_structure) do
    metadata = prepare_au_metadata(access_unit)

    buffer =
      access_unit
      |> Enum.reduce(<<>>, fn nalu, acc ->
        acc <> NALuParser.get_prefixed_nalu_payload(nalu, output_stream_structure)
      end)
      |> then(fn payload ->
        %Buffer{payload: payload, metadata: metadata, pts: pts, dts: dts}
      end)

    buffer
  end

  defp wrap_into_buffer(access_unit, pts, dts, :nalu, output_stream_structure) do
    access_unit
    |> Enum.zip(prepare_nalus_metadata(access_unit))
    |> Enum.map(fn {nalu, metadata} ->
      %Buffer{
        payload: NALuParser.get_prefixed_nalu_payload(nalu, output_stream_structure),
        metadata: metadata,
        pts: pts,
        dts: dts
      }
    end)
  end

  @spec prepare_au_metadata(AUSplitter.access_unit()) :: Buffer.metadata()
  defp prepare_au_metadata(nalus) do
    keyframe? = Enum.any?(nalus, &keyframe?/1)

    nalus =
      nalus
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {nalu, i}, nalu_start ->
        metadata = %{
          metadata: %{
            h265: %{
              type: nalu.type
            }
          }
        }

        metadata =
          if i == length(nalus) - 1 do
            put_in(metadata, [:metadata, :h265, :end_access_unit], true)
          else
            metadata
          end

        metadata =
          if i == 0 do
            put_in(metadata, [:metadata, :h265, :new_access_unit], %{key_frame?: keyframe?})
          else
            metadata
          end

        {metadata, nalu_start + byte_size(nalu.payload)}
      end)
      |> elem(0)

    %{h265: %{key_frame?: keyframe?, nalus: nalus}}
  end

  @spec prepare_nalus_metadata(AUSplitter.access_unit()) :: [Buffer.metadata()]
  defp prepare_nalus_metadata(nalus) do
    keyframe? = Enum.any?(nalus, &keyframe?/1)

    Enum.with_index(nalus)
    |> Enum.map(fn {nalu, i} ->
      %{h265: %{type: nalu.type}}
      |> Bunch.then_if(
        i == 0,
        &put_in(&1, [:h265, :new_access_unit], %{key_frame?: keyframe?})
      )
      |> Bunch.then_if(i == length(nalus) - 1, &put_in(&1, [:h265, :end_access_unit], true))
    end)
  end

  @spec keyframe?(NALu.t()) :: boolean()
  defp keyframe?(nalu), do: nalu.type in NALuTypes.irap_nalus()

  @spec stream_format_sent?([Action.t()], CallbackContext.t()) :: boolean()
  defp stream_format_sent?(actions, %{pads: %{output: %{stream_format: nil}}}),
    do: Enum.any?(actions, &match?({:stream_format, _stream_format}, &1))

  defp stream_format_sent?(_actions, _ctx), do: true
end
