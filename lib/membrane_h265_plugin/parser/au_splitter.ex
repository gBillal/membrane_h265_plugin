defmodule Membrane.H265.Parser.AUSplitter do
  @moduledoc """
  Module providing functionalities to divide the binary
  h265 stream into access units.

  The access unit splitter's behaviour is based on *"7.4.2.4.4
  Order of NAL units and coded pictures and association to access units"*
  of the *"ITU-T Rec. H.265 (08/2021)"* specification.

  The current implementation splits the nalu into access units either when a non vcl nalu with type
  `:vps`, `:sps`, `:pps`, `:aud`, `:prefix_sei` is encountered or when the vcl nal unit type is <= 9 or
  between 16 and 25 and has `first_slice_segment_in_pic_flag` is set.
  """
  require Logger

  alias Membrane.H265.Parser.{NALu, NALuTypes}

  @typedoc """
  A structure holding a state of the access unit splitter.
  """
  @opaque t :: %__MODULE__{
            nalus_acc: [NALu.t()],
            fsm_state: :first | :second,
            previous_nalu: NALu.t() | nil,
            access_units_to_output: [access_unit_t()]
          }

  @enforce_keys [
    :nalus_acc,
    :fsm_state,
    :previous_nalu,
    :access_units_to_output
  ]
  defstruct @enforce_keys

  @doc """
  Returns a structure holding a clear state of the
  access unit splitter.
  """
  @spec new() :: t()
  def new() do
    %__MODULE__{
      nalus_acc: [],
      fsm_state: :first,
      previous_nalu: nil,
      access_units_to_output: []
    }
  end

  @vcl_nalus NALuTypes.vcl_nalu_types()
  @non_vcl_nalus_at_au_beginning [:vps, :sps, :pps, :prefix_sei]
  @non_vcl_nalus_at_au_end [:fd, :eos, :eob, :suffix_sei]

  @typedoc """
  A type representing an access unit - a list of logically associated NAL units.
  """
  @type access_unit_t() :: list(NALu.t())

  # split/2 defines a finite state machine with two states: :first and :second.
  # The state :first describes the state before reaching the primary coded picture NALu of a given access unit.
  # The state :second describes the state after processing the primary coded picture NALu of a given access unit.

  @doc """
  Splits the given list of NAL units into the access units.

  It can be used for a stream which is not completely available at the time of function invocation,
  as the function updates the state of the access unit splitter - the function can
  be invoked once more, with new NAL units and the updated state.
  Under the hood, `split/2` defines a finite state machine
  with two states: `:first` and `:second`. The state `:first` describes the state before
  reaching the first segment of a coded picture NALu of a given access unit. The state `:second`
  describes the state after processing the first segment of the coded picture of a given
  access unit.
  """
  @spec split(list(NALu.t()), t()) :: {list(access_unit_t()), t()}
  def split(nalus, state)

  def split([first_nalu | rest_nalus], %{fsm_state: :first} = state) do
    cond do
      access_unit_first_slice_segment?(first_nalu) ->
        split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: state.nalus_acc ++ [first_nalu],
              fsm_state: :second,
              previous_nalu: first_nalu
          }
        )

      (first_nalu.type == :aud and state.nalus_acc == []) or
        first_nalu.type in @non_vcl_nalus_at_au_beginning or
        NALu.int_type(first_nalu) in 41..44 or
          NALu.int_type(first_nalu) in 48..55 ->
        split(
          rest_nalus,
          %__MODULE__{state | nalus_acc: state.nalus_acc ++ [first_nalu]}
        )

      true ->
        Logger.warning("AUSplitter: Improper transition")
        return(state)
    end
  end

  def split([first_nalu | rest_nalus], %{fsm_state: :second} = state) do
    previous_nalu = state.previous_nalu

    cond do
      first_nalu.type == :aud or first_nalu.type in @non_vcl_nalus_at_au_beginning ->
        split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: [first_nalu],
              fsm_state: :first,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      access_unit_first_slice_segment?(first_nalu) ->
        split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: [first_nalu],
              previous_nalu: first_nalu,
              access_units_to_output: state.access_units_to_output ++ [state.nalus_acc]
          }
        )

      first_nalu.type == previous_nalu.type or
        first_nalu.type in @non_vcl_nalus_at_au_end or
        NALu.int_type(first_nalu) in 45..47 or
          NALu.int_type(first_nalu) in 56..63 ->
        split(
          rest_nalus,
          %__MODULE__{
            state
            | nalus_acc: state.nalus_acc ++ [first_nalu],
              previous_nalu: first_nalu
          }
        )

      true ->
        Logger.warning("AUSplitter: Improper transition")
        return(state)
    end
  end

  def split([], state) do
    {state.access_units_to_output |> Enum.filter(&(&1 != [])),
     %__MODULE__{state | access_units_to_output: []}}
  end

  defp return(state) do
    {state.access_units_to_output |> Enum.filter(&(&1 != [])),
     %__MODULE__{state | access_units_to_output: []}}
  end

  @doc """
  Returns a list of NAL units which are hold in access unit splitter's state accumulator
  and sets that accumulator empty.

  These NAL units aren't proved to form a new access units and that is why they haven't yet been
  output by `Membrane.H265.Parser.AUSplitter.split/2`.
  """
  @spec flush(t()) :: {list(NALu.t()), t()}
  def flush(state) do
    {state.nalus_acc, %{state | nalus_acc: []}}
  end

  defp access_unit_first_slice_segment?(nalu) do
    nalu.type in @vcl_nalus and
      nalu.parsed_fields.first_slice_segment_in_pic_flag == 1
  end
end
