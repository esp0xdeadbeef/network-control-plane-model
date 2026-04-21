# Implementation Plan

Goal: make CPM the strict S88 join point where forwarding truth and realization truth meet, with no hidden recovery and no renderer-specific reinterpretation.

## Current S88 posture

This repo is already the strongest on contract language:

- forwarding is canonical logical truth
- inventory is canonical realization truth
- mismatch must fail

The remaining issues are mostly about making renderer-relevant realized data explicit enough that renderers no longer need local fallback heuristics.

## Main gaps

1. Renderer-facing shape is not documented deeply enough.
   - Runtime targets, overlay projections, realized interfaces, WAN group identity, service realization, and host-level bindings need a clearer contract.

2. Some renderer assumptions still get repaired downstream.
   - Containerlab currently needed shims around overlay transport shape.
   - NixOS currently imposes strict WAN-uplink mapping requirements that are not yet first-class in the common story.

3. Realization identity is explicit in code but not fully explicit in docs.
   - Which names are authoritative for nodes, links, overlays, lanes, runtime targets, and host uplinks should be stated clearly.

4. CPM-to-renderer contract boundaries are not fully standardized across both renderers.

## Work items

1. Add a “renderer contract” section to `README.md`.
   - Document the canonical emitted structures for:
     - sites
     - runtime targets
     - nodes
     - uplinks
     - overlays
     - services
     - realized interfaces
     - route/control-plane mode selections

2. Promote WAN-group identity to explicit common contract.
   - If renderers need host-facing WAN group selection, CPM should expose that as first-class realized data rather than relying on renderer-local interpretation.

3. Standardize overlay realization output.
   - Make `terminateOn`, node addresses, provider metadata, and site-peer identity stable and documented.
   - Renderers should consume these fields directly.

4. Standardize runtime-target semantics.
   - Explicitly define what `routingMode`, `bgp`, hosted services, and container/host deployment hints mean at the CPM boundary.

5. Add cross-renderer conformance tests.
   - One focused case should validate that the same CPM output is accepted by both containerlab and NixOS renderers without renderer-local semantic repair.

## Exit criteria

- Both renderers can consume CPM data with minimal translation.
- WAN/uplink selection semantics are explicit and shared.
- Overlay realization is documented as a stable CPM artifact.
- “Strict join, no guessing” remains true in both code and downstream usage.

## Test impact

- Keep invariant and no-guessing suites.
- Add one cross-renderer CPM fixture gate for a multi-site overlay example.
- Add explicit assertions for runtime-target and overlay output shape.
