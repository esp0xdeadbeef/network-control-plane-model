# network-control-plane-model

`network-control-plane-model` accepts an explicit forwarding model and produces a deterministic `control_plane_model`.

---

## Normative implementation

The Nix path is the only normative implementation.

`./src/python-reference/` is reference-only historical material. It does not define accepted input shape, required fields, invariants, or test outcomes.

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

---

## Explicit interface semantics

When `site.nodes` is present, `site.nodes.<node>.interfaces.<ifname>` is validated explicitly.

Every interface requires:

* `kind`

Additional required fields by kind:

* `kind = "tenant"` requires `tenant`
* `kind = "overlay"` requires `overlay`
* `kind = "wan"` requires `upstream`

Semantic repair from links, prefixes, names, or topology shape is not accepted.

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

