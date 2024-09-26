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

    :persistent_term.put(
      :spit_states_throttle_io,
      # &Logger.debug("count(#{&1}, #{inspect(&2)})")
      fn _, _ -> false = :persistent_term.erase(:spit_states_throttle_io) end
    )

    :persistent_term.put(
      :spit_states_throttle_qlen,
      # &Logger.debug("count(#{&1}, #{inspect(&2)})")
      fn _, _ -> false = :persistent_term.erase(:spit_states_throttle_qlen) end
    )
  end

  defmodule Job do
    def init(_, :ping), do: :pong
    def init(_, :idle), do: :idle
    def init(_, :stop), do: :stop
    def init(_, :real), do: {:set, :test_state}

    def init(_, :read), do: {:return, :value}

    def init(_, :store, value), do: {:set, [value: value]}
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
    assert ^states = SplitStates.handle(states, {Job, :two}, event, true)

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
    assert ^expected = SplitStates.init(states, {Job, :one}, [:real], caller, nil, :trace_token)
  end

  test "return result" do
    states = Container.new()
    caller = {:callback, &Logger.info("ret: #{inspect(&1)}")}

    # direct return, no state added
    assert ^states = SplitStates.init(states, {Job, :one}, [:read], caller, nil, :trace_token)
    # malformed caller
    assert ^states = SplitStates.init(states, {Job, :one}, [:read], :caller, nil, :trace_token)
  end

  test "save and return result" do
    states = Container.new()
    caller = {:callback, &Process.put(:result, &1)}

    # delayed return, result stored in the state
    value = [{:abc, 123}, %{a: :b}]
    states_ = SplitStates.init(states, {Job, :one}, [:store, value], caller, nil, dbg_tt())
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
      def init(_, :first), do: {:return, :first}

      # create state, return result, delete state
      def init(_, :second), do: [{:set, :a_state}, :return, :stop]
    end

    defmodule B do
      def init(_, target, variant) do
        [{:set, :b_state}, {:call, target, [variant], :result}]
      end

      def handle(:b_state, :result, value) do
        [{:return, value}, :stop]
      end

      def handle(:b_state, :result) do
        [:return, :stop]
      end
    end

    states = Container.new()
    caller1 = {:callback, &Process.put(:result, &1)}
    caller2 = {:callback, fn -> Process.put(:result, :void) end}
    caller3 = {:callback, fn -> Process.put(:result) end}

    assert ^states = SplitStates.init(states, {B, :one}, [{A, :two}, :first], caller1)
    assert :first = Process.get(:result)

    assert ^states = SplitStates.init(states, {B, :one}, [{A, :two}, :second], caller2)
    assert :void = Process.get(:result)

    assert ^states = SplitStates.init(states, {B, :one}, [{A, :two}, :second], caller3)
  end

  test "test tell" do
    defmodule A do
      def init(_), do: {:set, nil}
      def handle(_, :stop), do: :stop
    end

    defmodule B do
      # note: reverse order!
      def init(_), do: [{:tell, {A, nil}, [:stop]}, {:call, {A, nil}, [], :ret}]
    end

    states = Container.new()
    assert ^states = SplitStates.init(states, {B, nil}, [], nil, nil, dbg_tt())
  end

  test "test cast" do
    defmodule A do
      def init({_, x}) do
        Process.put(:result, x)
        :idle
      end
    end

    defmodule B do
      def init({_, :one}, x), do: {:cast, {A, x}, []}

      def init({_, :two}, x) do
        choke = {:choke, 10, 100, ChokeTimer}
        {:cast, {A, x}, [], choke}
      end
    end

    states = Container.new()

    assert ^states = SplitStates.init(states, {B, :one}, [:lalala], nil, nil, dbg_tt())
    assert :lalala = Process.get(:result)

    assert ^states =
             SplitStates.init(states, {B, :two}, [:pepepe], nil, nil, dbg_tt())
             |> Map.delete(:choke)

    assert :pepepe = Process.get(:result)
  end

  test "state update, multiple subscribers" do
    defmodule Server do
      def init(_), do: {:set, %{}}
      def handle(state, :upd, val), do: [{:return, :ok}, {:set, Map.put(state, :value, val)}]
      def handle(state, :run), do: [{:return, state[:value]}, :stop]
    end

    defmodule Client do
      def init(_, target), do: [{:set, []}, {:call, target, [], :ret}]
      def handle(_, :ret, :result), do: :stop
      def handle(_, :ret, _), do: :idle
    end

    states = Container.new()
    # dbg = fn n -> {:callback, &Logger.debug("trc#{n} #{inspect(&1)}: #{inspect(&2)}")} end
    states_ = Enum.reduce(1..20, states, &SplitStates.init(&2, {Client, &1}, [{Server, :x}]))
    states2 = SplitStates.handle(states_, {Server, :x}, [:upd, :result])
    assert ^states = SplitStates.handle(states2, {Server, :x}, [:run])
  end

  test "test simple timer implementation" do
    defmodule Timer do
      def init(target, ms, val) do
        tag = make_ref()
        tref = Process.send_after(self(), {:timeout, tag, target}, ms)
        {:set, {tref, tag, val}}
      end

      # input for timer "fire" event
      def handle({_tref, tag, val}, tag, :fire) do
        # return result to subscriber(s)
        {:stop, val}
      end

      # "stop" command will cancel timer
      def handle({tref, tag, _val}, :stop) do
        Process.cancel_timer(tref)

        # flash timer event if any
        receive do
          {:timeout, ^tag, _} ->
            :ok
        after
          0 ->
            :ok
        end

        :stop
      end
    end

    # start 100ms timer
    states = Container.new()
    caller = {:callback, &Process.put(:result, &1)}
    states1 = SplitStates.init(states, {Timer, :one}, [100, :a], caller)
    states2 = SplitStates.init(states1, {Timer, :two}, [200, :b], caller)

    # timers were not fired yet
    assert nil == Process.get(:result)

    # handle 1st timer event
    states3 =
      receive do
        {:timeout, tag, target} ->
          SplitStates.handle(states2, target, [tag, :fire])
      end

    # first timer is fired
    assert :a = Process.get(:result)

    # cancel second timer
    states4 = SplitStates.handle(states3, {Timer, :two}, [:stop])

    # handle 2st timer event
    states5 =
      receive do
        {:timeout, tag, target} ->
          SplitStates.handle(states4, target, [tag, :fire])
      after
        300 ->
          states4
      end

    # second timer was canceled, so result is set by the 1st one
    assert :a = Process.get(:result)

    # all states are done
    assert ^states = states5
  end

  defmodule Wait do
    def loop(states, max) do
      receive do
        {:timeout, timer} ->
          ret = SplitStates.handle(states, timer, [:fire])
          Process.get(:result) < max && ret |> loop(max)
      after
        1000 -> {:error, :timeout}
      end
    end
  end

  defmodule ChokeTimer do
    def init({_, until} = me) do
      Process.send_after(self(), {:timeout, me}, abs_to_ms(until))
      {:set, []}
    end

    def handle(_, :fire), do: :return

    @units 1 |> System.convert_time_unit(:millisecond, :native)
    defp abs_to_ms(abstime) do
      case abstime - System.monotonic_time() do
        diff when diff > 0 ->
          (diff / @units) |> ceil

        _ ->
          0
      end
    end
  end

  defmodule Doer do
    def init({_, x}), do: {:return, x}
  end

  test "test basic throttle" do
    states = Container.new()
    caller = {:callback, &Process.put(:result, &1)}
    max = 100

    choke = {:test_choke, 10, 100, ChokeTimer}
    states_ = 1..max |> Enum.reduce(states, &SplitStates.init(&2, {Doer, &1}, [], caller, choke))
    assert 10 == Process.get(:result)

    Wait.loop(states_, max)
    assert max == Process.get(:result)

    choke = {:test_choke, 1000, 1, ChokeTimer}
    1..max |> Enum.reduce(states, &SplitStates.init(&2, {Doer, &1}, [], caller, choke))
    assert 100 == Process.get(:result)
  end

  test "test deep throttle" do
    defmodule Prep do
      def init({_, x}) do
        choke = {:test_choke, 10, 100, ChokeTimer}
        [{:set, []}, {:call, {Doer, x}, [], :done, choke}]
      end

      def handle(_, :done, x) do
        Process.put(:result, x)
        :stop
      end
    end

    max = 20
    states = Container.new()
    states_ = 1..max |> Enum.reduce(states, &SplitStates.init(&2, {Prep, &1}, []))
    assert 10 == Process.get(:result)

    # delay to test the case when queue may be completely flushed at once
    Process.sleep(500)
    Wait.loop(states_, max)
    assert max == Process.get(:result)
  end
end
