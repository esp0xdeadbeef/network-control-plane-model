# TODO — network-control-plane-model

## Purpose

Consume **network-forwarding-model (v6)** and emit a **fully explicit, deterministic runtime model**.

The control-plane-model:

* does not infer
* does not repair
* does not guess intent

It validates input and elevates it into explicit runtime semantics.

---

## Core invariants

### 1. No inference anywhere

* [ ] No topology-based inference
* [ ] No name-based inference
* [ ] No route-pattern inference
* [ ] No fallback/default semantics

If meaning is not explicit → fail

---

### 2. Forwarding-model is the only authority

* [ ] Require `meta.networkForwardingModel` (schema v6)
* [ ] Reject solver-era input (`meta.solver`, pair-based transit, etc.)
* [ ] Consume only canonical fields:

  * nodes, links, transit.adjacencies, transit.ordering
  * attachments, domains, tenantPrefixOwners
  * loopback, interfaces

---

### 3. Stable link identity is absolute

* [ ] Use `links.*.id` and `transit.adjacencies[].id` as canonical
* [ ] `transit.ordering` must be stable link IDs only
* [ ] Reject pair-based ordering
* [ ] Fail on missing / duplicate / inconsistent IDs

---

### 4. Runtime model must be fully explicit

Each emitted interface must include:

* [ ] `runtimeIfName`
* [ ] `renderedIfName`
* [ ] `runtimeTarget`
* [ ] exactly one backing reference (`link` or `attachment`)
* [ ] `addr4`, `addr6`
* [ ] `routes`

Renderer must not:

* inspect topology
* resolve links
* infer placement

---

### 5. Semantic elevation is CPM responsibility

CPM converts structure → explicit behavior.

#### Interfaces

* [ ] `interfaceRole` is required
* [ ] no role inference from topology or naming

#### Routes

* [ ] no semantic use of `proto`
* [ ] routes must carry explicit intent (default / internal / egress)

#### Egress

* [ ] explicit per-node egress definition required
* [ ] renderer must not derive egress from routes

---

### 6. Loopbacks are first-class

* [ ] consume node `loopback` explicitly
* [ ] do not synthesize loopbacks
* [ ] representation (interface vs field) must be consistent
* [ ] ownership must match `tenantPrefixOwners`

---

### 7. Validation is strict and centralized

* [ ] single validation authority
* [ ] fail on any contract mismatch
* [ ] no compatibility normalization

---

### 8. Output must be renderer-ready

* [ ] all runtime data available in one canonical structure
* [ ] no cross-tree lookups required
* [ ] no duplicated topology views

---

## Done when

* [ ] forwarding-model v6 is consumed explicitly
* [ ] no solver-era assumptions remain
* [ ] no implicit semantics remain
* [ ] renderer performs zero decision-making
* [ ] output is deterministic and st

