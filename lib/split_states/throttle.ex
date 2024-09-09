defmodule SplitStates.Throttle do
  alias __MODULE__, as: State
  use TypedStruct

  typedstruct do
    field(:kind, atom())
    field(:window, pos_integer())
    field(:step, pos_integer())
    field(:next_ts, pos_integer())
    field(:queue, :queue.queue(), default: :queue.new())
  end

  # init state and process input
  def start({_target, _event, _caller, {kind, rate, ms, _timer}, _tt}) do
    count_io(:both, kind)
    window = ms |> System.convert_time_unit(:millisecond, :native)
    step = div(window, rate)

    %State{
      kind: kind,
      window: window,
      step: step,
      next_ts: System.monotonic_time() + step
    }
  end

  # process input
  def proc(%State{queue: queue, step: step, window: window, kind: kind} = state, input) do
    if :queue.is_empty(queue) do
      now = System.monotonic_time()
      next = state.next_ts + step
      stop = now + window
      count_io(:in, kind)

      cond do
        next < now ->
          count_io(:out, kind)
          {true, %State{state | next_ts: now + step}}

        next <= stop ->
          count_io(:out, kind)
          {true, %State{state | next_ts: next}}

        true ->
          until = next - window
          update_qlen(:inc, kind)
          {false, until, %State{state | queue: :queue.in(input, queue)}}
      end
    else
      count_io(:in, kind)
      update_qlen(:inc, kind)
      {false, %State{state | queue: :queue.in(input, queue)}}
    end
  end

  # process timer event
  def flush(%State{queue: queue, step: step, window: window, kind: kind} = state) do
    now = System.monotonic_time()
    next = state.next_ts
    stop = now + window
    {next, queue, acc} = pop_send(kind, next, step, stop, queue, [])

    next = if next < now, do: now + step, else: next
    state = %State{state | next_ts: next, queue: queue}

    if :queue.is_empty(queue) do
      {acc, state}
    else
      until = next + step - window
      {until, acc, state}
    end
  end

  defp pop_send(kind, next, step, stop, queue, acc) when next + step <= stop do
    case :queue.out(queue) do
      {{:value, x}, queue} ->
        count_io(:out, kind)
        update_qlen(:dec, kind)
        pop_send(kind, next + step, step, stop, queue, [x | acc])

      {:empty, queue} ->
        {next, queue, Enum.reverse(acc)}
    end
  end

  defp pop_send(_, next, _step, _stop, queue, acc) do
    {next, queue, Enum.reverse(acc)}
  end

  defp count_io(dir, kind) do
    with func when is_function(func, 2) <-
           :persistent_term.get(:spit_states_throttle_io, nil) do
      try do
        func.(dir, kind)
      rescue
        _ -> nil
      end
    end
  end

  defp update_qlen(dir, kind) do
    with func when is_function(func, 2) <-
           :persistent_term.get(:spit_states_throttle_qlen, nil) do
      try do
        func.(dir, kind)
      rescue
        _ -> nil
      end
    end
  end
end
