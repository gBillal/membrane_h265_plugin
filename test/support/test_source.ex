defmodule Membrane.H265.Support.TestSource do
  @moduledoc false

  use Membrane.Source

  def_options mode: [],
              output_raw_stream_structure: [default: :annexb]

  def_output_pad :output,
    flow_control: :push,
    accepted_format:
      any_of(
        %Membrane.RemoteStream{type: :bytestream},
        Membrane.H265
      )

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{mode: opts.mode, output_raw_stream_structure: opts.output_raw_stream_structure}}
  end

  @impl true
  def handle_parent_notification(actions, _ctx, state) do
    {actions, state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    stream_format =
      case state.mode do
        :bytestream ->
          %Membrane.RemoteStream{type: :bytestream}

        :nalu_aligned ->
          %Membrane.H265{alignment: :nalu, stream_structure: state.output_raw_stream_structure}

        :au_aligned ->
          %Membrane.H265{alignment: :au, stream_structure: state.output_raw_stream_structure}
      end

    {[stream_format: {:output, stream_format}], state}
  end
end
