defmodule Membrane.H265.ProcessAllTest do
  @moduledoc false

  use ExUnit.Case
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions
  alias Membrane.H265
  alias Membrane.Testing.Pipeline

  defp make_pipeline(in_path, out_path) do
    structure = [
      child(:file_src, %Membrane.File.Source{chunk_size: 40_960, location: in_path})
      |> child(:parser, H265.Parser)
      |> child(:sink, %Membrane.File.Sink{location: out_path})
    ]

    Pipeline.start_link_supervised(structure: structure)
  end

  defp perform_test(filename, tmp_dir, timeout) do
    in_path = "../fixtures/input-#{filename}.h265" |> Path.expand(__DIR__)
    out_path = Path.join(tmp_dir, "output-all-#{filename}.h265")

    assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path, out_path)
    assert_pipeline_play(pid)
    assert_end_of_stream(pid, :sink, :input, timeout)

    assert File.read(out_path) == File.read(in_path)

    Pipeline.terminate(pid, blocking?: true)
  end

  describe "ProcessAllPipeline should" do
    @describetag :tmp_dir

    test "process all 10 320p frames with main still picture profile", ctx do
      perform_test("10-480x320-mainstillpicture", ctx.tmp_dir, 1000)
    end

    test "process all 10 480p frames with main 10 profile", ctx do
      perform_test("10-640x480-main10", ctx.tmp_dir, 1000)
    end

    test "process all 10 1080p frames", ctx do
      perform_test("10-1920x1080", ctx.tmp_dir, 1000)
    end

    test "process all 15 720p frames with more than one temporal sub-layer", ctx do
      perform_test("15-1280x720-temporal-id-1", ctx.tmp_dir, 1000)
    end

    test "process all 30 480p frames with no b frames", ctx do
      perform_test("30-640x480-no-bframes", ctx.tmp_dir, 1000)
    end

    test "process all 30 720p frames with rext profile", ctx do
      perform_test("30-1280x720-rext", ctx.tmp_dir, 1000)
    end

    test "process all 60 1080p frames", ctx do
      perform_test("60-1920x1080", ctx.tmp_dir, 1000)
    end
  end
end
