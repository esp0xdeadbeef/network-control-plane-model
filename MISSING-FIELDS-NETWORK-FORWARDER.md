# MISSING-FIELDS-NETWORK-FORWARDER

The forwarding model already contains a lot of useful structure.

However, a few fields are still missing if the goal is to build the control plane **deterministically** without guessing.

The core issue is simple:

The control-plane builder should not have to infer routing intent from topology alone.

These are upstream modeling gaps.
They should be solved in an authoritative upstream model, not guessed later in downstream control-plane code or renderers.

---

## Missing fields

### 1. Routing participation per adjacency

The model shows that nodes are connected, but it does not clearly say whether a link should participate in routing.

A connection existing is not enough.

Some links may be:

* forwarding-only
* static-route only
* dynamic-routing capable
* management-only

A field should exist to mark this explicitly.

Example:

* `"routingParticipation": true`

Or per adjacency:

* `"adjacencies": [{ "name": "access-to-policy", "routingParticipation": true }]`

Without this, the control plane must guess which links should run routing protocols.

---

### 2. Prefix advertisement intent

The forwarding model can describe who owns a prefix, but it does not clearly describe **how far that prefix may be advertised**.

A field should exist to express propagation intent.

Example:

* `"prefixAdvertisementScope": "site"`

Possible values could be:

* `local`
* `site`
* `upstream`
* `global`

Without this, the control plane must infer export behavior from structure, which is ambiguous.

---

### 3. Route propagation boundaries

The model does not clearly describe where route propagation must stop.

This is different from ownership.

A prefix may be valid in one part of the topology but should not cross certain boundaries.

A field should exist to describe that.

Example:

* `"routePropagationBoundary": "site-edge"`

Or:

* `"routePropagationBoundaries": ["site-edge", "uplink-edge"]`

Without this, downstream logic must invent stop conditions.

---

### 4. Node routing capabilities

Node roles imply routing behavior, but that behavior is not explicit enough.

A node should clearly declare what it is able to do.

Examples:

* `"supportsRouting": true`
* `"canOriginatePrefixes": true`
* `"canPropagateRoutes": true`

Or as a grouped object:

* `"routingCapabilities": { "supportsRouting": true, "canOriginatePrefixes": true, "canPropagateRoutes": true }`

Without this, control-plane logic has to infer capabilities from role names.

---

### 5. Control-plane participation

Some nodes may forward traffic but should not participate in routing.

That should be explicit.

Example:

* `"participatesInControlPlane": false`

This matters because forwarding behavior and routing behavior are not always the same thing.

Without this field, the control plane may incorrectly treat forwarding nodes as routing nodes.

---

### 6. Uplink routing policy

Uplinks are currently visible as forwarding structure, but routing behavior toward them may need extra metadata.

Examples:

* whether only a default route should be imported
* whether local prefixes may be advertised upstream
* whether the uplink is primary or backup

A field should exist to describe this explicitly.

Examples:

* `"uplinkRoutingPolicy": "default-only"`
* `"uplinkRoutingPolicy": "full-table"`
* `"uplinkRoutingPolicy": "backup-default"`

Without this, the control plane must infer uplink behavior from topology shape.

---

### 7. Integrated inventory information

The control-plane model often needs endpoint and service inventory information.

Today that may exist as a separate input, but ideally it should be part of the same authoritative model.

That inventory can help determine:

* endpoint ownership
* service placement
* exposure
* reachability
* policy evaluation

Example shape:

* `"inventory": { "endpoints": { "dns-site": { "zone": "site", "ipv4": ["10.10.10.53"], "ipv6": ["fd42:dead:beef:10::53"] } } }`

This avoids split-brain inputs where downstream code must load extra side files.

---

## Why these fields matter

Without these fields, the control plane must infer behavior from forwarding structure.

Inference creates ambiguity.

Explicit fields make it easier to achieve:

* deterministic control-plane construction
* renderer independence
* stable network architecture
* less duplicated logic downstream

---

## Important note

These are upstream schema gaps.

That does **not** necessarily mean every field must live in the forwarding model exactly as-is.

What matters is that the authoritative upstream model exposes enough explicit semantics for deterministic control-plane generation.

Downstream repositories should not have to guess.

---

## Minimal example

A future model does not need to be huge.
It just needs to be explicit enough.

A small example could look like this:

* `"adjacencies": [{ "name": "access-to-policy", "routingParticipation": true }]`
* `"routingCapabilities": { "supportsRouting": true, "canOriginatePrefixes": false, "canPropagateRoutes": true }`
* `"prefixAdvertisementScope": "site"`
* `"routePropagationBoundaries": ["uplink-edge"]`
* `"participatesInControlPlane": true`
* `"uplinkRoutingPolicy": "default-only"`

That alone would already remove a lot of downstream inference.

---

## Summary

The missing problem is not just “more fields”.

The real problem is that the control plane still has to guess too much.

The upstream model should explicitly describe:

* which links participate in routing
* which nodes participate in the control plane
* how far prefixes may propagate
* where propagation must stop
* what routing capabilities nodes have
* how uplinks behave
* what inventory exists

Once those semantics exist upstream, downstream control-plane and renderer code becomes much simpler and more deterministic.


