# network-control-plane-model

A deterministic builder that converts an **explicit forwarding model** plus an explicit **realization inventory** into a **platform-independent control-plane model**.

The control-plane model does **not** generate vendor or device configuration.
Instead, it produces a stable, explicit intermediate representation that downstream renderers can consume.

This project is intentionally **strict**.
It does not repair missing forwarding intent.
It does not repair missing realization data.
It joins the two explicit input contracts and fails when they do not match.

---

# Disclaimer

This project exists primarily to support my own infrastructure.

If it happens to be useful to others, great — but **pin a specific version**.
The internal schema may change between versions.
Backward compatibility is **not guaranteed**.

Pull requests are welcome, but changes that conflict with the architectural model are unlikely to be merged.

This repository is not trying to be a universal control-plane synthesizer for every possible input style.
It is an **architecture-first, contract-first control-plane composition layer**.

---

# Normative implementation

The Nix implementation is the only normative implementation.

Any historical or reference material outside the main Nix path is **non-normative**.
It does not define accepted input shape, required fields, invariants, or test outcomes.

In practice, that means the behavior defined by `./src/main.nix` and the test suite is the contract.

---

# Reality check

If your network is small enough that you can just hand-write a few static routes, interface bindings, and firewall rules, this project is **completely unnecessary**.

You could solve many small cases with something as small as:

```bash
ip route add 10.20.0.0/24 via 10.0.0.2 dev wg0
```

Done.

This repository exists because I chose to build something **much more complicated** instead.

The goal is not merely to have connectivity.
The goal is to have:

* deterministic control-plane construction
* strict authority boundaries
* explicit forwarding intent
* explicit realization coverage
* renderer-independent intermediate output
* failure on mismatch instead of silent repair

So yes — for a trivial setup, this is overkill.
But once the network stops being trivial, the explicit contract starts to matter.

---

# Project intent

This repository sits between the forwarding model and the renderer.

Its job is to take:

* explicit logical forwarding intent
* explicit realization inputs

and produce:

* explicit control-plane structure
* explicit realized interface bindings
* deterministic renderer input

It is therefore a **composition layer**, not a forwarding solver and not a renderer.

It does not decide what the network means.
It decides how already-declared meaning becomes an explicit, concrete control-plane model.

---

# What this project does

`network-control-plane-model`:

* validates the explicit forwarding-model contract
* validates the explicit realization inventory
* joins logical intent with concrete realization inputs
* resolves already-declared control-plane bindings
* emits deterministic control-plane data for downstream renderers

Typical output includes things like:

* node identity
* tenant and overlay attachment identity
* transit adjacency identity and ordering
* policy attachment identity
* uplink and egress realization
* concrete interface bindings
* renderer-consumable control-plane structure

The result is **platform-independent control-plane data**, not final platform configuration.

---

# What this project does not do

This project does **not**:

* derive forwarding intent from inventory
* invent transit topology
* invent missing tenant identity
* invent missing overlay membership
* invent missing policy tags
* invent missing BGP peers
* invent missing uplink intent
* generate Cisco configuration
* generate Junos configuration
* generate NixOS configuration
* silently repair missing realization coverage

If the forwarding model says something must exist, and the inventory does not realize it, evaluation must fail.

---

# Position in the architecture

This repository is part of a multi-stage pipeline.

| Layer                   | Responsibility                                                                |
| ----------------------- | ----------------------------------------------------------------------------- |
| **Compiler**            | defines communication semantics and canonical staged topology                 |
| **Forwarding model**    | constructs deterministic forwarding structure from the canonical staged model |
| **Control plane model** | joins explicit forwarding intent with explicit realization inputs             |
| **Renderer**            | emits platform-specific configuration                                         |

Pipeline:

```text
intent
  ↓
compiler
  ↓
forwarding model
  ↓
control plane model
  ↓
renderer
```

This repository implements the **control-plane model stage**.

---

# Architectural boundary

`network-control-plane-model` is a control-plane composition layer.

It does not derive forwarding intent from inventory.

It does not depend on forwarding-model internals beyond the explicit model contract consumed at its input boundary.

It requires `inventory.nix` to explicitly realize **every forwarding-model reference that must exist at control-plane realization time**.

If the forwarding model references an adapter, attachment point, interface, uplink, node, or any other realizable target and `inventory.nix` does not define the corresponding concrete realization input, evaluation must fail.

A complete forwarding model is required.
A complete realization inventory is also required.

Missing realization data is an error, not a defaulting opportunity.

`inventory.nix` is therefore not optional glue.
It is a required realization-side contract that must explicitly cover all concrete targets referenced by the forwarding model.

If the forwarding model names something that must appear in the control-plane result, `inventory.nix` must define the realization data needed to make that happen.

That includes, at minimum:

* concrete adapter mappings
* interface bindings
* uplink realization
* node realization metadata
* other realization-time data required to turn explicit forwarding intent into explicit control-plane output

The control-plane layer must crash on mismatch.
Not warn.
Not guess.
Crash.

---

# Model stance

The forwarding model is the canonical source of logical truth.

The control-plane model is the canonical realized result.

That distinction matters.

The forwarding model defines **what the network means**.
The control-plane model defines **what a renderer needs in order to realize that meaning concretely**.

This repository therefore sits on a hard boundary:

* forwarding semantics come from the forwarding model
* realization coverage comes from inventory
* emitted control-plane structure comes from joining those two explicit inputs

No third source of truth is allowed to appear implicitly during evaluation.

---

# Renderer neutrality

The model is renderer-neutral.

It is not NixOS-specific.

Its purpose is to provide enough explicit, normalized control-plane information for any downstream renderer to build a target-specific configuration for:

* a Cisco router
* a Juniper router
* a NixOS router
* a lab or simulation target
* any other router implementation

The renderer is responsible for **emission in the target platform grammar**.
It is not responsible for inventing topology, inferring policy membership, reconstructing forwarding semantics, or guessing missing realization coverage.

In other words:

> one explicit control-plane model, many possible renderers.

---

# Canonical explicit model contract

A valid input passed to `./src/main.nix` must provide:

* `enterprise` as an attribute set
* `enterprise.<name>.site` as an attribute set
* `enterprise.<name>.site.<name>.transit` explicitly
* `enterprise.<name>.site.<name>.transit.adjacencies` explicitly
* `enterprise.<name>.site.<name>.transit.ordering` explicitly
* `enterprise.<name>.site.<name>.transport.overlays` as either an attribute set or a list when present

The control-plane layer expects explicit structure.
It does not accept missing contract fields as an invitation to derive intent from other data.

---

# Explicit transit

`site.transit` is required and must not be inferred.

Each adjacency must contain exactly two endpoints.
Each adjacency must define transport-local attachment explicitly.

Each endpoint must contain:

* `unit`
* `local`
* at least one of `local.ipv4` or `local.ipv6`

Example:

```nix
{
  transit = {
    adjacencies = [
      {
        endpoints = [
          {
            unit = "policy-1";
            local.ipv4 = "10.0.0.1";
          }
          {
            unit = "access-1";
            local.ipv4 = "10.0.0.2";
          }
        ];
        routingParticipation = false;
      }
    ];

    ordering = [
      [ "policy-1" "access-1" ]
    ];
  };
}
```

Transit is explicit authority.
It is not a thing the control-plane layer may reconstruct from naming, topology shape, or inventory hints.

---

# Dedicated transit lanes

This stage is where explicit forwarding intent meets explicit realization.

When the forwarding-model emits multiple transit adjacencies between the same two units (policy-driven “dedicated lanes”, e.g. via
`transit.dedicatedLanes = true`), the control-plane model must:

* preserve each lane’s stable identity in `control_plane_model.data.<enterprise>.<site>.transit.adjacencies`
* require `inventory.nix` to explicitly realize each lane (VLAN/subif/etc is an inventory concern)
* fail hard if any required lane is missing realization coverage (no guessing / no collapse)

---

# Explicit overlays

`site.transport.overlays` must be either:

* an attribute set, or
* a list

No other type is accepted.

Overlay membership, endpoint identity, and attachment semantics must already be explicit in the model passed into the control-plane layer.

No overlay repair from inventory, naming conventions, link shape, or forwarding heuristics is accepted.

---

# Explicit interface semantics

When `site.nodes` is present, `site.nodes.<node>.interfaces.<ifname>` is validated explicitly.

Every interface requires:

* `kind`

Additional required fields by kind:

* `kind = "tenant"` requires `tenant`
* `kind = "overlay"` requires `overlay`
* `kind = "wan"` requires `upstream`

Semantic repair from links, prefixes, names, topology shape, or inventory defaults is not accepted.

---

# Explicit tenant identity

Tenant identity must be present on tenant-facing interfaces.

For `role = "access"`, at least one interface must be:

* `kind = "tenant"`
* with explicit `tenant`

Prefix ownership, node naming, contracts, and topology heuristics are not accepted as substitutes.

---

# Explicit policy and firewall tags

When `communicationContract` is present, `site.policy.interfaceTags` is required.

`site.policy.interfaceTags` is the canonical explicit source of policy tags.

Every tenant, external, service, or named relation member referenced by `communicationContract` must already appear as a value in `site.policy.interfaceTags`.

Topology-derived policy tags are not accepted.

---

# Explicit WAN intent and realization boundary

WAN intent is declared by the forwarding model.
WAN device realization is attached by the control-plane layer.

The forwarding model must explicitly declare:

* which nodes are eligible for external egress
* which logical uplinks those nodes consume

The control-plane layer then joins that intent with inventory-backed interface realization **without changing forwarding semantics**.

This means:

* forwarding intent decides whether a node is exit-capable
* forwarding intent decides which uplink names a node consumes
* inventory only provides the concrete host/interface realization for those already-declared uplinks
* WAN port discovery does not define policy or forwarding meaning
* WAN port discovery does not override forwarding intent

For an exit-capable node, the control-plane layer resolves the concrete WAN interface by matching explicit uplink intent against inventory-backed realization inputs.

The resolved WAN interface is then rendered into the final `control_plane_model`.

---

# Explicit BGP session intent

If `site.bgp.mode = "bgp"`, then `site.bgp.sessions` is required and must be non-empty.

Each session must declare explicit endpoint node names:

* `a`
* `b`

Optional:

* `rr`

Every referenced node must exist in `site.nodes`.

Role-derived BGP sessions are not accepted.

---

# No hidden inference

`network-control-plane-model` does not invent forwarding structure.

It does not infer:

* missing transit adjacencies
* missing transit ordering
* missing tenant identity
* missing overlay identity
* missing policy tags
* missing BGP peers
* missing uplink intent
* missing realization coverage

It only combines explicit forwarding intent with explicit realization data required to emit a concrete control-plane model.

---

# Input responsibility split

Responsibility is segmented as follows.

## Forwarding model

The forwarding model owns:

* topology and transit intent
* tenant-facing semantics
* policy membership and relation identity
* overlay intent
* egress and uplink intent
* explicit node-level control-plane semantics

## Inventory

The inventory owns:

* host realization
* device/interface attachment
* platform-specific render targets
* concrete WAN port availability
* node-to-platform realization metadata

## Control-plane model

`network-control-plane-model` owns:

* validating the explicit model contract
* validating realization-side coverage
* joining explicit forwarding intent with explicit realization inputs
* resolving concrete interface bindings from already-declared intent
* rendering deterministic control-plane output

---

# Determinism

Given the same explicit forwarding model and the same realization inventory, output is deterministic.

No hidden topology repair, role synthesis, or policy reconstruction is performed during model construction.

The repository is strict for a reason:

* same input should produce the same output
* missing data should fail the same way every time
* renderers should not need to reverse-engineer intent from partial results

---

# Genericity boundary

This project is **generic across renderers**, not generic across arbitrary control-plane philosophies.

That means:

* the output is platform-independent
* the same model may be rendered by different downstream targets
* the control-plane layer does not care whether the renderer emits NixOS, Cisco, Juniper, or something else

But it does **not** mean:

* the model accepts missing contracts and repairs them later
* renderers may reinterpret forwarding semantics
* inventory may define forwarding meaning retroactively

The genericity boundary is therefore:

> one explicit forwarding contract, one explicit realization contract, many possible renderers.

---

# Practical expectation for downstream renderers

If you write a renderer for this model, the expectation is simple:

* consume the explicit control-plane structure
* preserve the meaning already established upstream
* use the realized interface bindings already resolved here
* emit target-specific configuration
* do not repair missing intent by inventing policy
* do not reconstruct topology from partial hints

A renderer may choose **how** to emit the model.
It may not choose **whether the model means something else**.

---

# Test layout

Fixtures are committed under:

* `fixtures/passing/`
* `fixtures/failing/invariants/`
* `fixtures/failing/no-guessing/`

Direct test entrypoints:

* `tests/test-passing-fixtures.sh`
* `tests/test-failing-invariants.sh`
* `tests/test-no-guessing.sh`

---

# Running

Build a control-plane model from `intent.nix` + `inventory.nix`:

```bash
nix run .#compile-and-build-control-plane-model -- ./intent.nix ./inventory.nix ./output-control-plane-model.json
```

Or build from a precomputed forwarding-model JSON (plus optional inventory):

```bash
nix run .#debug -- ./output-network-forwarding-model.json ./inventory.nix ./output-control-plane-model.json
```

---

# Running tests

```bash
./tests/test-passing-fixtures.sh
./tests/test-failing-invariants.sh
./tests/test-no-guessing.sh
```

---

# Summary

This project is a deterministic control-plane composition layer.

It accepts:

* an explicit forwarding model
* an explicit realization inventory

and produces:

* a deterministic, explicit, renderer-neutral `control_plane_model`

It is:

* platform-independent
* renderer-neutral
* strict about authority boundaries
* explicit about realization coverage
* intolerant of guessing

The forwarding model defines what the network means.
The inventory defines how realizable targets exist concretely.
The control-plane model joins those two things and crashes when they do not line up.

That is the point.
Not a side effect.
