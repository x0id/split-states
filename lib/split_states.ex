defmodule SplitStates do
  require Logger
  require SplitStates.Container
  alias SplitStates.Container, as: Container

  def init(states, target, event, caller \\ nil, tt \\ nil) do
    [{:init, {target, event, caller, tt}}] |> loop([], states)
  end

  def handle(states, target, event) do
    [{:handle, {target, event}}] |> loop([], states)
  end

  defp loop({items, stack, states}), do: loop(items, stack, states)

  defp loop([], _, states), do: states

  defp loop([{:init, {target, event, caller, tt} = input} = item | items], stack, states) do
    trace(tt, :init, input)

    case Container.exists?(states, target) do
      false ->
        trace(tt, :new, {target, event})

        tts = Container.add_tt(tt)
        callers = Container.add_caller(caller, tt)
        stack = [{target, tts, callers, nil} | stack]

        construct(target, event)
        |> tap(&trace(tt, :result, &1))
        |> apply_result(item, items, stack, states)

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

  defp return({:callback, fun}, result, tt) when is_function(fun, 1) do
    trace(tt, :ret_func, result)
    fun.(result)
    :idle
  end

  defp return({:tagged, origin, tag}, result, tt) do
    trace(tt, :tagged, {tag, result})
    {:handle, {origin, [tag, result]}}
  end

  defp return(caller, _result, _tt) do
    Logger.error("malformed caller: #{inspect(caller)}")
    :idle
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
    item = {:init, {target, event, caller, tts}}
    {[item | items], stack, states}
  end

  # return result to caller(s)
  defp apply_result(
         {:return, result},
         _item,
         items,
         [{_target, _tts, callers, _state} | _tail] = stack,
         states
       ) do
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
  defp construct({mod, _key}, args) do
    try do
      apply(mod, :init, args)
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
