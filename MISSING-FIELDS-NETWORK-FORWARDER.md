# MISSING-FIELDS-NETWORK-FORWARDER

The forwarding model currently contains most information required to derive routing behavior.

However, several fields are missing or underspecified.

These fields are required to make the forwarding model a complete and correct abstraction for control plane construction.

These are **upstream issues**.

They must be solved in the forwarding model generator, not in this repository.

---

# Missing structural definitions

## Explicit routing adjacency intent

The forwarding model provides transit adjacency ordering but does not explicitly define which adjacencies should participate in routing protocols.

A field should exist that explicitly marks routing-capable adjacencies.

Example concept:

routingAdjacencyCandidates

This would identify interfaces that are eligible for routing protocol sessions.

---

## Prefix advertisement scope

The forwarding model identifies prefix owners but does not define advertisement scope.

A field should exist that defines how far prefixes should propagate.

Example concept:

prefixAdvertisementScope

Typical scopes may include:

- local
- site
- upstream
- global

Without this information, the control plane must infer advertisement behavior.

---

## Route propagation boundaries

The forwarding model describes traversal but does not explicitly define where route propagation must stop.

A field describing propagation boundaries should exist.

Example concept:

routePropagationBoundaries

These boundaries prevent uncontrolled propagation.

---

## Node routing capabilities

Node roles imply routing behavior but are not explicit.

Nodes should explicitly declare routing capabilities.

Example concept:

routingCapabilities

Such a structure would indicate whether a node:

- supports routing
- can originate prefixes
- can propagate routes

---

## Control-plane participation

Some nodes may participate in forwarding but not in routing.

A field should explicitly describe this.

Example concept:

controlPlaneParticipation

Example semantics:

participatesInRouting = true/false

---

## Uplink routing hints

Uplinks are currently defined only in forwarding terms.

Routing behavior toward uplinks may require additional metadata.

Example concept:

uplinkRoutingPolicy

---

# Why these fields matter

Without these fields, the control plane model must infer behavior from forwarding structure.

Inference increases ambiguity.

Explicit definitions allow:

- deterministic control plane construction
- renderer independence
- stable network architecture

---

# Important note

These missing fields represent **limitations in the forwarding model schema**, not problems in this repository.

This module must assume the forwarding model will evolve to include these definitions.

Until then, deterministic default behavior may be required.
