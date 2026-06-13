# Development Plan

This project tracks its roadmap as issues — see the open issues labeled
[`plan`](https://github.com/atomantic/EscapeMint-Swift/issues?q=is%3Aissue+is%3Aopen+label%3Aplan)
on the repository's Issues page. Managed by `/do:replan --issues`.

For completed work see [DONE.md](DONE.md). For project context see
[README.md](README.md) and [CLAUDE.md](CLAUDE.md).

## Deferred Refactors

Candidates identified during a code-quality pass but intentionally skipped to
avoid behavior risk in the financial accumulation paths — these are large but
**cohesive** single-pass loops where splitting trades real regression risk for
marginal clarity. Pick up only with dedicated tests guarding each extracted step:

- [ ] `runBacktest` (`Engine/BacktestEngine.swift`, ~lines 236-523, 288 lines):
      could split into data-prep, state-init, per-entry processing, and
      metrics-finalization helpers. The core DCA simulation loop mutates many
      interdependent accumulators per entry (interest/dividends → recommendation
      → buy/sell → entry recording) — extract only with characterization tests.
- [ ] `computeFundMetricsForFund` (`Engine/FundEngine.swift`, ~lines 491-760,
      270 lines): pre-walk setup and post-walk gains/APY/state assembly are the
      separable seams; the entry walk itself is cohesive and should stay whole.
- [ ] `computeEntryRows` (`Engine/FundEngine.swift`, ~lines 898-1026): the
      ~105-line per-entry `.map` closure could become a named helper.
