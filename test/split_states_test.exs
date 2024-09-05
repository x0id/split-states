defmodule SplitStatesTest do
  require Logger
  use ExUnit.Case
  doctest SplitStates
  require SplitStates.Container
  alias SplitStates.Container, as: Container

  setup_all do
    :persistent_term.put(
      :spit_states_counter,
      # &Logger.debug("count(#{&1}, #{inspect(&2)})")
      fn _, _ -> false = :persistent_term.erase(:spit_states_counter) end
    )
  end

  defmodule Job do
    def init(:ping), do: :pong
    def init(:idle), do: :idle
    def init(:stop), do: :stop
    def init(:real), do: {:set, :test_state}

    def init(:read), do: {:return, :value}

    def init(:store, value), do: {:set, [value: value]}
    def handle([value: value], :read), do: {:return, value}
    def handle([value: value], :pop), do: [{:return, value}, :stop]
  end

  test "malformed input" do
    states = Container.new()
    event = [:ping]
    caller = nil
    assert ^states = SplitStates.init(states, :lalala, event, caller)
    assert ^states = SplitStates.init(states, {Jo_, :one}, event, caller)
    assert ^states = SplitStates.init(states, {Job, :one}, event, caller)
    assert ^states = SplitStates.handle(states, {Job, :two}, event)

    states = SplitStates.init(states, {Job, :two}, [:real])
    states = SplitStates.init(states, {Job, :two}, [:real])
    assert ^states = SplitStates.handle(states, {Job, :two}, [:real])
  end

  test "good target" do
    states = Container.new()
    caller = :test_caller

    # don't create a state on :idle result
    assert ^states = SplitStates.init(states, {Job, :one}, [:idle], caller)

    # don't create a state on :stop result
    assert ^states = SplitStates.init(states, {Job, :one}, [:stop], caller)

    # create a state with no trace token
    expected = %{{Job, :one} => {[], [{:test_caller, nil}], :test_state}}
    assert ^expected = SplitStates.init(states, {Job, :one}, [:real], caller)

    # create a state with trace token
    expected = %{{Job, :one} => {[:trace_token], [{:test_caller, :trace_token}], :test_state}}
    assert ^expected = SplitStates.init(states, {Job, :one}, [:real], caller, :trace_token)
  end

  test "return result" do
    states = Container.new()
    caller = {:callback, &Logger.info("ret: #{inspect(&1)}")}

    # direct return, no state added
    assert ^states = SplitStates.init(states, {Job, :one}, [:read], caller, :trace_token)
    # malformed caller
    assert ^states = SplitStates.init(states, {Job, :one}, [:read], :caller, :trace_token)
  end

  test "save and return result" do
    states = Container.new()
    caller = {:callback, &Process.put(:result, &1)}

    # delayed return, result stored in the state
    value = [{:abc, 123}, %{a: :b}]
    states_ = SplitStates.init(states, {Job, :one}, [:store, value], caller, dbg_tt())
    assert ^states_ = SplitStates.handle(states_, {Job, :one}, [:read])
    assert ^value = Process.get(:result)
    assert ^states = SplitStates.handle(states_, {Job, :one}, [:pop])
    assert ^value = Process.get(:result)
  end

  defp dbg_tt() do
    {:callback, &Logger.debug("trace #{inspect(&1)}: #{inspect(&2)}")}
  end

  test "call another state" do
    defmodule A do
      # return with no state creation
      def init(:first), do: {:return, :first}

      # create state, return result, delete state
      def init(:second), do: [{:set, :a_state}, {:return, :second}, :stop]
    end

    defmodule B do
      def init(target, variant) do
        [{:set, :b_state}, {:call, target, [variant], :result}]
      end

      def handle(:b_state, :result, value) do
        [{:return, value}, :stop]
      end
    end

    states = Container.new()
    caller = {:callback, &Process.put(:result, &1)}

    assert ^states = SplitStates.init(states, {B, :one}, [{A, :two}, :first], caller)
    assert :first = Process.get(:result)

    assert ^states = SplitStates.init(states, {B, :one}, [{A, :two}, :second], caller)
    assert :second = Process.get(:result)
  end

  test "state update, multiple subscribers" do
    defmodule Server do
      def init(), do: {:set, %{}}
      def handle(state, :upd, val), do: [{:return, :ok}, {:set, Map.put(state, :value, val)}]
      def handle(state, :run), do: [{:return, state[:value]}, :stop]
    end

    defmodule Client do
      def init(target), do: [{:set, []}, {:call, target, [], :ret}]
      def handle(_, :ret, :result), do: :stop
      def handle(_, :ret, _), do: :idle
    end

    states = Container.new()
    # dbg = fn n -> {:callback, &Logger.debug("trc#{n} #{inspect(&1)}: #{inspect(&2)}")} end
    states_ = Enum.reduce(1..20, states, &SplitStates.init(&2, {Client, &1}, [{Server, :x}]))
    states2 = SplitStates.handle(states_, {Server, :x}, [:upd, :result])
    assert ^states = SplitStates.handle(states2, {Server, :x}, [:run])
  end
end
