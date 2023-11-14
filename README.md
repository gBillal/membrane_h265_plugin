# Membrane H265 Plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_h265_plugin.svg)](https://hex.pm/packages/membrane_h265_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_h265_plugin)


Membrane H265 parser. It is the Membrane element responsible for parsing the incoming h265 stream. The parsing is done as a sequence of the following steps:

  * Splitting the h265 stream into stream NAL units, based on the "Annex B" of the "ITU-T Rec. H.265 (08/2021)"
  * Parsing the NAL unit headers, so that to read the type of the NAL unit
  * Parsing the NAL unit body with the appropriate scheme, based on the NAL unit type read in the step before
  * Aggregating the NAL units into a stream of access units

The output of the element is the incoming binary payload, enriched with the metadata describing the division of the payload into access units.

## Installation

The package can be installed by adding `membrane_h265_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_h265_plugin, "~> 0.4.0"}
  ]
end
```

## Usage

The following pipeline takes H265 file, parses it, and then decodes it to the raw video.

```elixir
defmodule Decoding.Pipeline do
  use Membrane.Pipeline

  alias Membrane.{File, H265}

  @impl true
  def handle_init(_ctx, _opts) do
    structure =
      child(:source, %File.Source{location: "test/fixtures/input-10-1920x1080.h265"})
      |> child(:parser, H265.Parser)
      |> child(:decoder, H265.FFmpeg.Decoder)
      |> child(:sink, %File.Sink{location: "output.raw"})

    {[spec: structure], nil}
  end

  @impl true
  def handle_element_end_of_stream(:sink, _ctx_, state) do
    {[terminate: :normal], state}
  end
end
```
