defmodule SplitStates.Metrics do
  # Optional metric hooks. Hooks are stored in :persistent_term (a low-cost
  # read path); the keys are an implementation detail — use the functions
  # below to install/remove hooks.

  @counter :split_states_counter
  @throttle_io :split_states_throttle_io
  @throttle_qlen :split_states_throttle_qlen

  # install hook called on state count changes: fun.(:inc | :dec, module)
  def set_counter_hook(fun) when is_function(fun, 2),
    do: :persistent_term.put(@counter, fun)

  # install hook called on throttle input/output: fun.(:in | :out | :both, kind)
  def set_throttle_io_hook(fun) when is_function(fun, 2),
    do: :persistent_term.put(@throttle_io, fun)

  # install hook called on throttle queue length changes: fun.(:inc | :dec, kind)
  def set_throttle_qlen_hook(fun) when is_function(fun, 2),
    do: :persistent_term.put(@throttle_qlen, fun)

  def clear_counter_hook(), do: :persistent_term.erase(@counter)
  def clear_throttle_io_hook(), do: :persistent_term.erase(@throttle_io)
  def clear_throttle_qlen_hook(), do: :persistent_term.erase(@throttle_qlen)

  # internal invocation points
  @doc false
  def counter(op, key), do: invoke(@counter, op, key)

  @doc false
  def throttle_io(dir, kind), do: invoke(@throttle_io, dir, kind)

  @doc false
  def throttle_qlen(dir, kind), do: invoke(@throttle_qlen, dir, kind)

  defp invoke(key, a, b) do
    with func when is_function(func, 2) <- :persistent_term.get(key, nil) do
      try do
        func.(a, b)
      rescue
        _ -> nil
      end
    end
  end
end
