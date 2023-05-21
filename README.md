# Membrane H265 Plugin

Membrane H265 parser. It is the Membrane element responsible for parsing the incoming h265 stream. The parsing is done as a sequence of the following steps:

  * splitting the h265 stream into stream NAL units, based on the "Annex B" of the "ITU-T Rec. H.265 (08/2021)"
  * Parsing the NAL unit headers, so that to read the type of the NAL unit
  * Parsing the NAL unit body with the appropriate scheme, based on the NAL unit type read in the step before
  * Aggregating the NAL units into a stream of access units

The output of the element is the incoming binary payload, enriched with the metadata describing the division of the payload into access units.

## Installation

The package can be installed by adding `membrane_h265_plugin` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_template_plugin, github: "gBillal/membrane_h265_plugin", tag: "v0.1.0"}
  ]
end
```
