defmodule SplitStates do
  require Logger
  alias SplitStates.Container, as: Container
  alias SplitStates.Throttle, as: Throttle

  def init(states, target, event, caller \\ nil, choke \\ nil, tt \\ nil) do
    [{:init, {target, event, caller, tt}, choke}] |> loop([], states)
  end

  def handle(states, target, event, verbose \\ false) do
    [{:handle, {target, event}, verbose}] |> loop([], states)
  end

  defp loop({items, stack, states}), do: loop(items, stack, states)

  defp loop([], _, states), do: states

  defp loop([{:init, {target, event, caller, tt} = input, choke} = item | items], stack, states) do
    trace(tt, :init, input)

    case Container.exists?(states, target) do
      false ->
        case throttle(choke, input, states) do
          {true, states} ->
            trace(tt, :new, {target, event})

            tts = Container.add_tt(tt)
            callers = Container.add_caller(caller, tt)
            stack = [{target, tts, callers, nil} | stack]

            construct(target, event)
            |> tap(&trace(tt, :result, &1))
            |> apply_result(item, items, stack, states)

          {false, states} ->
            {items, stack, states}

          {false, kind, timer, until, states} ->
            {items, stack, states} |> set_throttle_timer(kind, timer, until)
        end

      true ->
        trace(tt, :result, :subscribe)
        {items, stack, states |> Container.subscribe(target, caller, tt)}
    end
    |> loop()
  end

  defp loop(
         [{:handle, {target, event} = input, _} = item | items],
         [{target, tts, _callers, state} | _] = stack,
         states
       ) do
    trace(tts, :handle_stack, input)

    process(target, event, state)
    |> tap(&trace(tts, :result, &1))
    |> apply_result(item, items, stack, states)
    |> loop()
  end

  defp loop([{:flush_throttle, kind, timer} | items], stack, states) do
    flush_throttle_queue(kind, timer, items, stack, states)
    |> loop()
  end

  defp loop([{:handle, {target, event} = input, verbose} = item | items], stack, states) do
    case Container.fetch(states, target) do
      {:ok, {tts, callers, state}} ->
        trace(tts, :handle, input)

        process(target, event, state)
        |> tap(&trace(tts, :result, &1))
        |> apply_result(item, items, [{target, tts, callers, state} | stack], states)
        |> loop()

      :error ->
        if verbose do
          Logger.error("target #{inspect(target)} not found")
          Logger.debug("event: #{inspect(event)}")
          Logger.debug("stack: #{inspect(stack)}")
        end

        loop(items, stack, states)
    end
  end

  # throttle input
  defp throttle({kind, _, _, timer} = choke, input, states) do
    case Container.fetch(states, kind) do
      {:ok, {_, _, state}} ->
        case Throttle.proc(state, input) do
          {result, state} ->
            {result, states |> Container.put(kind, state)}

          {false, until, state} ->
            {false, kind, timer, until, states |> Container.put(kind, state)}
        end

      :error ->
        state = Throttle.start(choke)
        {true, states |> Container.put(kind, state)}
    end
  end

  defp throttle(nil, _, states), do: {true, states}

  defp flush_throttle_queue(kind, timer, items, stack, states) do
    case Container.fetch(states, kind) do
      {:ok, {_, _, state}} ->
        case Throttle.flush(state) do
          {inputs, state} ->
            states = states |> Container.put(kind, state)
            items = inputs |> place_items(items)
            {items, stack, states}

          {until, inputs, state} ->
            states = states |> Container.put(kind, state)
            items = inputs |> place_items(items)
            {items, stack, states} |> set_throttle_timer(kind, timer, until)
        end

      :error ->
        {items, stack, states}
    end
  end

  defp set_throttle_timer({items, stack, states}, kind, timer, abstime) do
    target = {timer, abstime}
    caller = {:throttle, kind, timer}
    item = {:init, {target, [], caller, nil}, nil}
    {[item | items], stack, states}
  end

  defp place_items(inputs, items) do
    inputs |> Enum.reduce(items, &[{:init, &1, nil} | &2])
  end

  defp return({{:callback, fun}, tt}, result, acc) when is_function(fun) do
    trace(tt, :ret_func, result)

    try do
      apply(fun, result)
    rescue
      error ->
        Logger.error("can't call callback: #{inspect(error)}")
        Logger.debug("result: #{inspect(result)}")
    end

    acc
  end

  defp return({{:tagged, origin, tag}, tt}, result, acc) do
    trace(tt, :tagged, [tag | result])
    [{:handle, {origin, [tag | result]}, nil} | acc]
  end

  defp return({{:throttle, kind, timer}, tt}, _result, acc) do
    trace(tt, :throttle, kind)
    [{:flush_throttle, kind, timer} | acc]
  end

  defp return({caller, _tt}, result, acc) do
    Logger.error("malformed caller: #{inspect(caller)}")
    Logger.debug("result: #{inspect(result)}")
    acc
  end

  defp add_return_items(result, items, callers) do
    callers |> Enum.reduce(items, &return(&1, result, &2))
  end

  defp apply_return(result, items, [{_, _, callers, _} | _] = stack, states) do
    {add_return_items(result, items, callers), stack, states}
  end

  defp apply_result([], _item, items, stack, states), do: {items, stack, states}

  defp apply_result([head | tail], item, items, stack, states) do
    {items, stack, states} = apply_result(head, item, items, stack, states)
    apply_result(tail, item, items, stack, states)
  end

  defp apply_result(
         {:cast, target, event},
         _item,
         items,
         [{_origin, tts, _callers, _state} | _] = stack,
         states
       ) do
    item = {:init, {target, event, nil, tts}, nil}
    {[item | items], stack, states}
  end

  defp apply_result(
         {:cast, target, event, choke},
         _item,
         items,
         [{_origin, tts, _callers, _state} | _] = stack,
         states
       ) do
    item = {:init, {target, event, nil, tts}, choke}
    {[item | items], stack, states}
  end

  defp apply_result(
         {:call, target, event, tag},
         _item,
         items,
         [{origin, tts, _callers, _state} | _] = stack,
         states
       ) do
    caller = {:tagged, origin, tag}
    item = {:init, {target, event, caller, tts}, nil}
    {[item | items], stack, states}
  end

  defp apply_result(
         {:call, target, event, tag, choke},
         _item,
         items,
         [{origin, tts, _callers, _state} | _] = stack,
         states
       ) do
    caller = {:tagged, origin, tag}
    item = {:init, {target, event, caller, tts}, choke}
    {[item | items], stack, states}
  end

  defp apply_result({:tell, target, event}, _item, items, stack, states) do
    item = {:handle, {target, event}, nil}
    {[item | items], stack, states}
  end

  # return void to caller(s)
  defp apply_result(:return, _item, items, stack, states) do
    apply_return([], items, stack, states)
  end

  # return result to caller(s)
  defp apply_result({:return, result}, _item, items, stack, states) do
    apply_return([result], items, stack, states)
  end

  # save state and subscription
  defp apply_result(
         {:set, state},
         {:init, _, _},
         items,
         [{target, tts, callers, _state} | stack],
         states
       ) do
    entry = {target, tts, callers, state}
    {items, [entry | stack], states |> Container.add(entry)}
  end

  # update state
  defp apply_result(
         {:set, state},
         {:handle, _, _},
         items,
         [{target, tts, callers, _state} | stack],
         states
       ) do
    {items, [{target, tts, callers, state} | stack], states |> Container.put(target, state)}
  end

  # remove state
  defp apply_result(:stop, _item, items, [{target, _tts, _callers, _state} | stack], states) do
    {items, stack, states |> Container.delete(target)}
  end

  # return result to caller(s) and remove state
  defp apply_result({:stop, result}, _item, items, [{target, _, callers, _} | stack], states) do
    {add_return_items([result], items, callers), stack, states |> Container.delete(target)}
  end

  # do nothing
  defp apply_result(:idle, _item, items, stack, states) do
    {items, stack, states}
  end

  defp apply_result(result, item, items, stack, states) do
    Logger.error("malformed result: #{inspect(result)}")
    Logger.debug("item: #{inspect(item)}")
    Logger.debug("stack: #{inspect(stack)}")
    {items, stack, states}
  end

  # create new state
  defp construct({mod, _key} = target, args) do
    try do
      apply(mod, :init, [target | args])
    rescue
      error ->
        Logger.error("can't init state: #{inspect(error)}")
        Logger.debug("target: #{inspect(target)}")
        Logger.debug("args: #{inspect(args)}")
        :stop
    end
  end

  defp construct(target, _) do
    Logger.error("malformed target: #{inspect(target)}")
    :stop
  end

  # process event in context of existing state
  defp process(target, args, state) do
    try do
      apply(elem(target, 0), :handle, [state | args])
    rescue
      error ->
        Logger.error("can't update state: #{inspect(error)}")
        Logger.debug("target: #{inspect(target)}")
        Logger.debug("args: #{inspect(args)}")
        :idle
    end
  end

  defp trace({:callback, fun}, type, input) when is_function(fun, 2) do
    fun.(type, input)
  end

  defp trace([tt | tts], type, input) do
    trace(tt, type, input)
    trace(tts, type, input)
  end

  defp trace(_tt, _type, _input), do: nil
end
