# SplitStates

A library for running many asynchronous operations as pure state machines
multiplexed in a single event loop, instead of spawning a process per
operation.

## Motivation

The idiomatic Erlang/Elixir approach is to spawn a lightweight process per
unit of work, so each asynchronous operation can be written as if it were
synchronous. That works well in general, but falls short when:

1. **You need to manage the whole set of operations** — track them, wait for
   completion of each, cancel them as a group.
2. **You need short-term idempotency** — when two or more clients request the
   same operation while one is already in flight, the later callers should
   not start a duplicate; they should subscribe to the running one and share
   its result.

SplitStates takes the opposite approach: all operations run inside one
loop over a single complex state, which is split into sub-states — one per
operation. Sub-states are pure data keyed by a *target* (`{Module, key}`),
so deduplication, subscription, result sharing, introspection, and testing
come naturally.

## Design

- A **target** is a `{Module, key}` tuple identifying one state machine
  instance.
- The module implements plain functions (no processes, no side-effect
  requirements):
  - `init(target, args...)` — called when a target is first created;
  - `handle(state, args...)` — called for events sent to an existing target;
  - `serve(state, args...)` — optional; called when a caller attaches to an
    already-existing target (e.g. to return a cached result immediately).
- Callbacks don't perform effects directly — they *return* effects as data,
  which the loop interprets:

  | Effect | Meaning |
  |---|---|
  | `{:set, state}` | create/update this target's state |
  | `{:call, target, event, tag}` | start/attach to another target, subscribe for its result (tagged) |
  | `{:cast, target, event}` | start another target, don't subscribe |
  | `{:tell, target, event}` | send an event to an existing target |
  | `{:respond, result}` / `:respond` | send result to caller(s), keep subscriptions |
  | `{:return, result}` / `:return` | send result to caller(s), unsubscribe them |
  | `{:stop, result}` | send result to caller(s) and delete the state |
  | `:stop` | delete the state (no notification) |
  | `:idle` | do nothing |
  | a list of the above | apply several effects (see ordering note below) |

- If a caller `init`s a target that already exists, it is **subscribed** to
  it instead of starting a duplicate — this is the short-term idempotency:
  one execution, N subscribers, shared result.
- The host process (e.g. a GenServer) owns the container and feeds external
  events in:

  ```elixir
  states = SplitStates.Container.new()
  states = SplitStates.init(states, {MyOp, key}, [args], caller)
  states = SplitStates.handle(states, {MyOp, key}, [event])
  ```

  A `caller` is either `{:callback, fun}` or is implied by `{:call, ...}`
  from another state machine.

### Effect ordering

Effects in a returned list are applied in the listed order, but effects that
**enqueue work items** (`:call`, `:cast`, `:tell`, and returned results) are
prepended to the work queue — so the enqueued operations execute in
**reverse of the listed order** (LIFO). For example:

```elixir
# the :call executes first, the :tell second
[{:tell, {A, nil}, [:stop]}, {:call, {A, nil}, [], :ret}]
```

State-affecting effects such as `{:set, ...}` and `:stop` take effect
immediately, in listed order.

### Observability

- A *trace token* (`tt`) can be passed to `SplitStates.init/6` and is
  propagated through the whole call tree; use `{:callback, fun/2}` to log
  every step.
- Optional metric hooks can be installed via `SplitStates.Metrics`:

  ```elixir
  # state count changes: op is :inc | :dec, key is the target module
  SplitStates.Metrics.set_counter_hook(&MyMetrics.count(&1, &2))

  # throttle input/output: dir is :in | :out | :both, kind is the choke kind
  SplitStates.Metrics.set_throttle_io_hook(&MyMetrics.io(&1, &2))

  # throttle queue length changes: dir is :inc | :dec
  SplitStates.Metrics.set_throttle_qlen_hook(&MyMetrics.qlen(&1, &2))
  ```

  Each hook has a matching `clear_*_hook/0`. Hooks are optional; when not
  installed, the cost is a single `:persistent_term` lookup. Errors raised
  inside hooks are swallowed and never affect the loop.

### Throttling

`SplitStates.init/6` accepts a `choke` spec `{kind, rate, ms, timer_module}`
limiting the rate of operation starts; excess starts are queued and released
by a timer state machine (see `test/split_states_test.exs` for an example).

## Installation

The package is not published on Hex yet; add it as a GitHub dependency in
`mix.exs`:

```elixir
def deps do
  [
    {:split_states, github: "x0id/split-states"}
  ]
end
```
