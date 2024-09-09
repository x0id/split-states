defmodule SplitStates do
  require Logger
  alias SplitStates.Container, as: Container
  alias SplitStates.Throttle, as: Throttle

  def init(states, target, event, caller \\ nil, choke \\ nil, tt \\ nil) do
    [{:init, {target, event, caller, choke, tt}}] |> loop([], states)
  end

  def handle(states, target, event) do
    [{:handle, {target, event}}] |> loop([], states)
  end

  defp loop({items, stack, states}), do: loop(items, stack, states)

  defp loop([], _, states), do: states

  defp loop([{:init, {target, event, caller, _choke, tt} = input} = item | items], stack, states) do
    trace(tt, :init, input)

    case Container.exists?(states, target) do
      false ->
        case throttle(states, input) do
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

          {false, timer, until, states} ->
            {items, stack, states} |> set_throttle_timer(timer, until)
        end

      true ->
        trace(tt, :result, :subscribe)
        {items, stack, states |> Container.subscribe(target, caller, tt)}
    end
    |> loop()
  end

  defp loop(
         [{:handle, {target, event} = input} = item | items],
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

  defp loop([{:handle, {target, event} = input} = item | items], stack, states) do
    case Container.fetch(states, target) do
      {:ok, {tts, callers, state}} ->
        trace(tts, :handle, input)

        process(target, event, state)
        |> tap(&trace(tts, :result, &1))
        |> apply_result(item, items, [{target, tts, callers, state} | stack], states)
        |> loop()

      :error ->
        Logger.error("target #{inspect(target)} not found")
        loop(items, stack, states)
    end
  end

  # throttle input
  defp throttle(states, {_target, _event, _caller, {kind, _, _, timer}, _tt} = input) do
    case Container.fetch(states, kind) do
      {:ok, {_, _, state}} ->
        case Throttle.proc(state, input) do
          {result, state} ->
            {result, states |> Container.put(kind, state)}

          {false, until, state} ->
            {false, timer, until, states |> Container.put(kind, state)}
        end

      :error ->
        state = Throttle.start(input)
        {true, states |> Container.put(kind, state)}
    end
  end

  defp throttle(states, {_target, _event, _caller, nil = _choke, _tt}) do
    {true, states}
  end

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
            {items, stack, states} |> set_throttle_timer(timer, until)
        end

      :error ->
        {items, stack, states}
    end
  end

  defp set_throttle_timer({items, stack, states}, timer_module, abstime) do
    target = {timer_module, abstime}
    item = {:init, {target, [], nil, nil, nil}}
    {[item | items], stack, states}
  end

  defp place_items(inputs, items) do
    inputs
    |> Enum.reduce(items, fn
      {target, event, caller, _choke, tt}, acc ->
        [{:init, {target, event, caller, nil, tt}} | acc]
    end)
  end

  defp return({:callback, fun}, result, tt) when is_function(fun) do
    trace(tt, :ret_func, result)

    try do
      apply(fun, result)
    rescue
      error ->
        Logger.error("can't call callback: #{inspect(error)}")
        :stop
    end

    :idle
  end

  defp return({:tagged, origin, tag}, result, tt) do
    trace(tt, :tagged, [tag | result])
    {:handle, {origin, [tag | result]}}
  end

  defp return(caller, _result, _tt) do
    Logger.error("malformed caller: #{inspect(caller)}")
    :idle
  end

  defp apply_return(result, items, [{_, _, callers, _} | _] = stack, states) do
    items =
      callers
      |> Enum.reduce(items, fn {caller, tt}, acc ->
        case return(caller, result, tt) do
          :idle ->
            # return processed
            acc

          {:handle, _} = item ->
            # push back "call" item
            [item | acc]
        end
      end)

    {items, stack, states}
  end

  defp apply_result([], _item, items, stack, states), do: {items, stack, states}

  defp apply_result([head | tail], item, items, stack, states) do
    {items, stack, states} = apply_result(head, item, items, stack, states)
    apply_result(tail, item, items, stack, states)
  end

  defp apply_result(
         {:call, target, event, tag},
         _item,
         items,
         [{origin, tts, _callers, _state} | _] = stack,
         states
       ) do
    caller = {:tagged, origin, tag}
    item = {:init, {target, event, caller, nil, tts}}
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

  # timer module signals to flush throttle queue
  defp apply_result({:flush_throttle, kind, timer}, _item, items, stack, states) do
    {[{:flush_throttle, kind, timer} | items], stack, states}
  end

  # save state and subscription
  defp apply_result(
         {:set, state},
         {:init, _},
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
         {:handle, _},
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
