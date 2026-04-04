# network-control-plane-model

`network-control-plane-model` accepts an explicit forwarding model and produces a deterministic `control_plane_model`.

---

## Normative implementation

The Nix path is the only normative implementation.

`./src/python-reference/` is reference-only historical material. It does not define accepted input shape, required fields, invariants, or test outcomes.

---

## Architectural boundary

`network-control-plane-model` is a control-plane composition layer.

It does not derive forwarding intent from inventory.

It does not depend on `network-forwarding-model` internals beyond the explicit model contract consumed at its input boundary.

It requires `inventory.nix` to explicitly realize every forwarding-model reference that must exist at control-plane realization time.

If the forwarding model references an adapter, attachment point, interface, uplink, node, or other realizable target and `inventory.nix` does not define the corresponding concrete realization input, evaluation must fail.

A complete forwarding model is required, and a complete realization inventory is also required.

Missing realization data is an error, not a defaulting opportunity.

`inventory.nix` is the required realization-side contract that must explicitly cover all concrete targets referenced by the forwarding model.

If the forwarding model names something that must be realized in the control-plane output, `inventory.nix` must define it.

This includes concrete adapter mappings, interface bindings, uplink realization, and any other realization-time data required to turn explicit forwarding intent into an explicit control-plane model.

The control-plane layer must crash on any mismatch between forwarding-model references and inventory realization coverage.

The model is renderer-neutral.

It is not NixOS-specific.

Its purpose is to provide enough explicit, normalized control-plane information for any downstream renderer to build a target-specific configuration for a Cisco router, a Juniper router, a NixOS router, or any other router implementation.

The forwarding model is the canonical source of logical truth.

The control-plane model is the canonical rendered result.

---

## Canonical explicit model contract

A valid input passed to `./src/main.nix` must provide:

* `enterprise` as an attribute set.
* `enterprise.<name>.site` as an attribute set.
* `enterprise.<name>.site.<name>.transit` explicitly.
* `enterprise.<name>.site.<name>.transit.adjacencies` explicitly.
* `enterprise.<name>.site.<name>.transit.ordering` explicitly.
* `enterprise.<name>.site.<name>.transport.overlays` as either an attribute set or a list when present.

---

## Explicit transit

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

---

## Explicit overlays

`site.transport.overlays` must be either:

* an attribute set, or
* a list

No other type is accepted.

Overlay membership, endpoint identity, and attachment semantics must already be explicit in the model passed into the control-plane layer.

No overlay repair from inventory, naming conventions, link shape, or forwarding heuristics is accepted.

---

## Explicit interface semantics

When `site.nodes` is present, `site.nodes.<node>.interfaces.<ifname>` is validated explicitly.

Every interface requires:

* `kind`

Additional required fields by kind:

* `kind = "tenant"` requires `tenant`
* `kind = "overlay"` requires `overlay`
* `kind = "wan"` requires `upstream`

Semantic repair from links, prefixes, names, topology shape, or inventory defaults is not accepted.

---

## Explicit tenant identity

Tenant identity must be present on tenant-facing interfaces.

For `role = "access"`, at least one interface must be:

* `kind = "tenant"`
* with explicit `tenant`

Prefix ownership, node naming, contracts, and topology heuristics are not accepted as substitutes.

---

## Explicit policy and firewall tags

When `communicationContract` is present, `site.policy.interfaceTags` is required.

`site.policy.interfaceTags` is the canonical explicit source of policy tags.

Every tenant, external, service, or named relation member referenced by `communicationContract` must already appear as a value in `site.policy.interfaceTags`.

Topology-derived policy tags are not accepted.

---

## Explicit WAN intent and realization boundary

WAN intent is declared by the forwarding model.

WAN device realization is attached by the control-plane layer.

The forwarding model must explicitly declare which nodes are eligible for external egress and which logical uplinks they consume.

The control-plane layer joins that explicit intent with inventory-backed interface realization without changing forwarding semantics.

This means:

* forwarding intent decides whether a node is exit-capable
* forwarding intent decides which uplink names a node consumes
* inventory only provides the concrete host/interface realization for those already-declared uplinks
* WAN port discovery does not define policy or forwarding meaning
* WAN port discovery does not override forwarding intent

For an exit-capable node, the control-plane layer resolves the concrete WAN interface by matching explicit uplink intent against inventory-backed realization inputs.

The resolved WAN interface is then rendered into the final `control_plane_model`.

---

## Explicit BGP session intent

If `site.bgp.mode = "bgp"`, then `site.bgp.sessions` is required and must be non-empty.

Each session must declare explicit endpoint node names:

* `a`
* `b`

Optional:

* `rr`

Every referenced node must exist in `site.nodes`.

Role-derived BGP sessions are not accepted.

---

## No hidden inference

`network-control-plane-model` does not invent forwarding structure.

It does not infer:

* missing transit adjacencies
* missing transit ordering
* missing tenant identity
* missing overlay identity
* missing policy tags
* missing BGP peers
* missing uplink intent

It only combines explicit forwarding intent with explicit realization data required to emit a concrete control-plane model.

---

## Input responsibility split

Responsibility is segmented as follows:

### Forwarding model

The forwarding model owns:

* topology and transit intent
* tenant-facing semantics
* policy membership and relation identity
* overlay intent
* egress and uplink intent
* explicit node-level control-plane semantics

### Inventory

The inventory owns:

* host realization
* device/interface attachment
* platform-specific render targets
* concrete WAN port availability
* node-to-platform realization metadata

### Control-plane model

`network-control-plane-model` owns:

* validating the explicit model contract
* joining explicit forwarding intent with explicit realization inputs
* resolving concrete interface bindings from already-declared intent
* rendering deterministic control-plane output

---

## Renderer neutrality

`network-control-plane-model` does not target a single operating system or vendor.

It produces a deterministic, explicit control-plane model that is suitable as renderer input.

A downstream renderer should receive enough resolved information to build vendor-specific or platform-specific output without re-inventing forwarding intent.

That includes, at minimum, already-resolved control-plane structure such as:

* node identity
* transit adjacency identity and ordering
* tenant and overlay attachment identity
* policy attachment identity
* egress and uplink intent
* concrete realized interface bindings supplied through realization inputs

This allows separate renderers to consume the same model and emit configurations for Cisco, Juniper, NixOS, or any other router target.

The renderer is responsible only for emission in the target platform grammar.

It is not responsible for inventing topology, inferring policy membership, or reconstructing forwarding semantics.

## Determinism

Given the same explicit forwarding model and the same realization inventory, output is deterministic.

No hidden topology repair, role synthesis, or policy reconstruction is performed during rendering.

---

## Test layout

Fixtures are committed under:

* `fixtures/passing/`
* `fixtures/failing/invariants/`
* `fixtures/failing/no-guessing/`

Direct test entrypoints:

* `tests/test-passing-fixtures.sh`
* `tests/test-failing-invariants.sh`
* `tests/test-no-guessing.sh`

---

## Running tests

```bash
./tests/test-passing-fixtures.sh
./tests/test-failing-invariants.sh
./tests/test-no-guessing.sh
```

