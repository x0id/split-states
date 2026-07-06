# TODO

Outstanding concerns, roughly in priority order.

## Failure semantics: orphaned subscribers

The biggest issue. Bare `:stop` deletes a state *without notifying
subscribers*, and rescued callback errors degrade into exactly that
(`construct` error → `:stop`, `handle` error → `:idle`). A bug in one state
machine silently strands every caller subscribed to it: the caller's own
state stays in the container forever unless it runs its own timeout.

- [ ] On state deletion, always deliver something to remaining subscribers
      (e.g. `{:error, :stopped}`), so failure propagates the way a `:DOWN`
      message does in OTP.
- [ ] Reconsider the rescue-and-log policy: make it configurable, or reraise
      in dev/test so bugs surface instead of degrading silently.

## Behaviour contract

`init/serve/handle` are invoked via `apply` with events spliced as varargs —
no compile-time checks, no dialyzer coverage; mistakes surface only as logged
runtime errors.

- [ ] Define a `SplitStates.State` behaviour with `@callback`s (`serve`
      optional) and reference it from the docs.

## Effect ordering footgun

Effects that enqueue work items execute in reverse of the listed order
(LIFO). Documented in README and in a comment at `apply_result/5`, but:

- [ ] Consider making effect lists execute in written order (breaking
      change), or keep as-is and rely on documentation.

## Documentation

- [x] README with motivation and description.
- [ ] `@moduledoc`/`@doc` for `SplitStates`, `Container`, `Throttle`;
      publish on HexDocs.
- [ ] Document the `respond` vs `return` vs `stop` subscription lifecycle
      with examples.

## Throughput / scaling

Single-process design: one CPU-heavy callback stalls every operation.
Fine for I/O-bound work, but:

- [ ] Document the constraint and the pattern of delegating blocking calls
      to short-lived helper processes.
- [ ] Provide (or document) sharding of targets by key hash across a pool of
      worker processes — the container is pure, so this is straightforward.

## Backpressure

Throttle queue is unbounded; no backpressure mechanism besides rate
limiting.

- [ ] Consider a max queue length with an overflow policy (reject/drop).

## Tests

- [ ] Property-based tests for the loop invariants (no orphaned
      subscriptions, container empty after all ops complete, etc.).
