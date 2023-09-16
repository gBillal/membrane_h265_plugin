defmodule Membrane.H265.TimestampGenerationTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  import Membrane.H265.Support.Common

  alias Membrane.Buffer
  alias Membrane.H265.Parser
  alias Membrane.H265.Support.TestSource
  alias Membrane.Testing.{Pipeline, Sink}

  defmodule EnhancedPipeline do
    @moduledoc false

    use Membrane.Pipeline

    @impl true
    def handle_init(_ctx, args) do
      {[spec: args], %{}}
    end

    @impl true
    def handle_call({:get_child_pid, child}, ctx, state) do
      child_pid = Map.get(ctx.children, child).pid
      {[reply: child_pid], state}
    end
  end

  @h265_input_file_main "test/fixtures/input-10-640x480-main10.h265"
  @h265_input_timestamps_main [
    {0, -500},
    {33, -467},
    {167, -433},
    {100, -400},
    {67, -367},
    {133, -333},
    {300, -300},
    {233, -267},
    {200, -233},
    {267, -200}
  ]
  @h265_input_file_baseline "test/fixtures/input-10-1920x1080.h265"
  @h265_input_timestamps_baseline [0, 33, 67, 100, 133, 167, 200, 233, 267, 300]
                                  |> Enum.map(&{&1, &1 - 500})

  test "if the pts and dts are set to nil in :bytestream mode when framerate isn't given" do
    binary = File.read!(@h265_input_file_baseline)
    mode = :bytestream
    input_buffers = prepare_buffers(binary, mode)

    {:ok, _supervisor_pid, pid} =
      Pipeline.start_supervised(
        structure: [
          child(:source, %TestSource{mode: mode})
          |> child(:parser, Parser)
          |> child(:sink, Sink)
        ]
      )

    assert_pipeline_play(pid)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = prepare_buffers(binary, :au_aligned)

    Enum.each(output_buffers, fn buf ->
      payload = buf.payload
      assert_sink_buffer(pid, :sink, %Buffer{payload: ^payload, pts: nil, dts: nil})
    end)

    Pipeline.terminate(pid, blocking?: true)
  end

  test "if the pts and dts are generated correctly for stream without frame reorder and no-bframes in :bytestream mode when framerate is given" do
    process_test(@h265_input_file_baseline, @h265_input_timestamps_baseline)
  end

  test "if the pts and dts are generated correctly in :bytestream mode when framerate is given" do
    process_test(@h265_input_file_main, @h265_input_timestamps_main)
  end

  test "if the pts and dts are generated correctly without dts offset in :bytestream mode when framerate is given" do
    process_test(@h265_input_file_main, @h265_input_timestamps_main, false)
  end

  defp process_test(file, timestamps, dts_offset \\ true) do
    binary = File.read!(file)
    mode = :bytestream
    input_buffers = prepare_buffers(binary, mode)

    framerate = {30, 1}

    pid =
      Pipeline.start_supervised!(
        structure: [
          child(:source, %TestSource{mode: mode})
          |> child(:parser, %Membrane.H265.Parser{
            generate_best_effort_timestamps: %{framerate: framerate, add_dts_offset: dts_offset}
          })
          |> child(:sink, Sink)
        ]
      )

    assert_pipeline_play(pid)
    send_buffers_actions = for buffer <- input_buffers, do: {:buffer, {:output, buffer}}
    Pipeline.message_child(pid, :source, send_buffers_actions ++ [end_of_stream: :output])

    output_buffers = prepare_buffers(binary, :au_aligned)

    output_buffers
    |> Enum.zip(timestamps)
    |> Enum.each(fn {%Buffer{payload: ref_payload}, {ref_pts, ref_dts}} ->
      {ref_pts, ref_dts} = if dts_offset, do: {ref_pts, ref_dts}, else: {ref_pts, ref_dts + 500}
      assert_sink_buffer(pid, :sink, %Buffer{payload: payload, pts: pts, dts: dts})

      assert {ref_payload, ref_pts, ref_dts} ==
               {payload, Membrane.Time.as_milliseconds(pts, :round),
                Membrane.Time.as_milliseconds(dts, :round)}
    end)

    Pipeline.terminate(pid, blocking?: true)
  end
end
