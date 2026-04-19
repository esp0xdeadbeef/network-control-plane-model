# TODO

## Strictness / Failure Policy

- If CPM output fails because `inventory.nix` is incomplete:
  - fix only the example inventory so the model stays strict and the example becomes explicit instead of synthesized.
- If CPM output fails because `network-forwarding-model` output is incomplete:
  - crash and state what should exist in the forwarding model.

## Policy-Driven Dedicated Transit Links ("L2 Lanes")

Goal: keep all “mode”/policy decisions upstream and keep renderers as pure consumers.

When `network-forwarding-model` starts emitting multiple transit adjacencies between the same node pair (lane-aware p2p),
CPM must be able to bind those explicit adjacencies to explicit realization inputs without guessing.

Required work:

- Inventory binding:
  - allow inventory to bind transit lanes by stable adjacency `id` (or a stable lane key),
    mapping to concrete interface/VLAN/subif/etc (implementation detail is inventory-owned).
  - fail hard if any required lane lacks realization coverage.

- CPM output:
  - preserve lane identities and emit them explicitly in `control_plane_model.data.<enterprise>.<site>.transit`.
  - ensure any per-interface policy tagging is driven by explicit lane metadata (from forwarding model),
    not inferred from naming conventions.

- Tests:
  - add a fixture that expects multiple `transit.adjacencies[]` between the same two units and validates:
    - stable ids are preserved
    - inventory binding is required per lane
    - mismatch fails (no collapse / no “pick one”)
