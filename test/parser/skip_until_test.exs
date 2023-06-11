defmodule Membrane.H265.SkipUntilTest do
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

  describe "The parser should" do
    @describetag :tmp_dir

    test "skip the whole stream if no vps/sps/pps are provided", ctx do
      filename = "10-no-vps-sps-pps"
      in_path = "../fixtures/input-#{filename}.h265" |> Path.expand(__DIR__)
      out_path = Path.join(ctx.tmp_dir, "output-all-#{filename}.h265")

      assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path, out_path)
      assert_pipeline_play(pid)
      refute_sink_buffer(pid, :sink, _)

      Pipeline.terminate(pid, blocking?: true)
    end

    test "skip until IRAP frame is provided", ctx do
      filename = "vps-sps-pps-no-irap"
      in_path = "../fixtures/input-#{filename}.h265" |> Path.expand(__DIR__)
      out_path = Path.join(ctx.tmp_dir, "output-#{filename}.h265")
      ref_path = "test/fixtures/reference-#{filename}.h265"
      assert {:ok, _supervisor_pid, pid} = make_pipeline(in_path, out_path)
      assert_pipeline_play(pid)
      assert_end_of_stream(pid, :sink)
      assert File.read(out_path) == File.read(ref_path)
      Pipeline.terminate(pid, blocking?: true)
    end
  end
end
