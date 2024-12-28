defmodule SplitStates.Container do
  def new(), do: Map.new()

  def exists?(states, target), do: Map.has_key?(states, target)

  def fetch(states, target), do: Map.fetch(states, target)

  def add_tt(tt, list \\ [])
  def add_tt(nil, list), do: list
  def add_tt(tt, list), do: [tt | list]

  def add_caller(caller, tt, list \\ [])
  def add_caller(nil, _, list), do: list
  def add_caller(caller, tt, list), do: [{caller, tt} | list]

  # add new state and subscription
  def add(states, {target, tts, callers, state}) do
    result = Map.put(states, target, {tts, callers, state})
    map_size(result) > map_size(states) && update_counter(:inc, target)
    result
  end

  # add no new subscription
  def subscribe(states, _target, nil, nil), do: states

  # add new subscription
  def subscribe(states, target, caller, tt) do
    Map.update!(states, target, fn {tts, callers, state} ->
      {add_tt(tt, tts), add_caller(caller, tt, callers), state}
    end)
  end

  # remove all subscriptions of the given target
  def del_subs(states, target) do
    case Map.fetch(states, target) do
      {:ok, {_, _, state}} ->
        Map.put(states, target, {[], [], state})

      _ ->
        states
    end
  end

  # add/update state
  def put(states, target, state) do
    result =
      Map.update(states, target, {[], [], state}, fn {tts, callers, _} ->
        {tts, callers, state}
      end)

    map_size(result) > map_size(states) && update_counter(:inc, target)
    result
  end

  # zap state
  def delete(states, target) do
    result = Map.delete(states, target)
    map_size(result) < map_size(states) && update_counter(:dec, target)
    result
  end

  defp update_counter(op, {mod, _}), do: update_counter(op, mod)

  defp update_counter(op, key) do
    with func when is_function(func, 2) <- :persistent_term.get(:spit_states_counter, nil) do
      try do
        func.(op, key)
      rescue
        _ -> nil
      end
    end
  end
end
