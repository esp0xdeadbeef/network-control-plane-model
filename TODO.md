# TODO

## Strictness / Failure Policy

- If CPM output fails because `inventory.nix` is incomplete:
  - fix only the example inventory so the model stays strict and the example becomes explicit instead of synthesized.
- If CPM output fails because `network-forwarding-model` output is incomplete:
  - crash and state what should exist in the forwarding model.

## Policy-Driven Dedicated Transit Links ("L2 Lanes")

Goal: keep all “mode”/policy decisions upstream and keep renderers as pure consumers.

`network-forwarding-model` now emits lane-aware transit adjacencies (multiple p2p links between the same staged units).

What we must preserve:

- Inventory binding:
  - keep strict per-lane realization requirements (missing any lane must hard-fail).
  - consider (future) allowing binding by adjacency `id` in addition to link name, to decouple realization from naming.

- Tests:
  - add a negative fixture that omits exactly one required lane binding and asserts a hard failure.
