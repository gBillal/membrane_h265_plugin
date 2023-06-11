defmodule AUSplitterTest do
  @moduledoc false

  use ExUnit.Case

  @test_files_names ["10-1920x1080", "10-480x320-mainstillpicture"]

  # These values were obtained with the use of FFmpeg
  @au_lengths_ffmpeg %{
    "10-1920x1080" => [133_766, 1517, 474, 311, 298, 200, 3257, 547, 209],
    "10-480x320-mainstillpicture" => [35202, 8912, 8878, 8850, 8845, 8854, 8819, 8823, 8787]
  }

  defmodule FullBinaryParser do
    @moduledoc false
    alias Membrane.H265.Parser.{
      AUSplitter,
      NALuParser,
      NALuSplitter
    }

    @spec parse(binary()) :: AUSplitter.access_unit_t()
    def parse(payload) do
      nalu_splitter = NALuSplitter.new()
      {nalus_payloads, nalu_splitter} = NALuSplitter.split(payload, nalu_splitter)
      {last_nalu_payload, _nalu_splitter} = NALuSplitter.flush(nalu_splitter)
      nalus_payloads = nalus_payloads ++ [last_nalu_payload]

      nalu_parser = NALuParser.new()

      {nalus, _nalu_parser} =
        Enum.map_reduce(nalus_payloads, nalu_parser, &NALuParser.parse(&1, &2))

      {aus, _au_splitter} = AUSplitter.split(nalus, AUSplitter.new())

      aus
    end
  end

  test "if the access unit lenghts parsed by access unit splitter are the same as access units lengths parsed by FFMPEG" do
    for name <- @test_files_names do
      full_name = "test/fixtures/input-#{name}.h265"
      binary = File.read!(full_name)

      aus = FullBinaryParser.parse(binary)

      au_lengths =
        for au <- aus,
            do:
              Enum.reduce(au, 0, fn %{payload: payload}, acc ->
                byte_size(payload) + acc
              end)

      assert au_lengths == @au_lengths_ffmpeg[name]
    end
  end
end
