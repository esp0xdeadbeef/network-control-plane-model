## network-control-plane-model

### 1. Render dynamic WAN interfaces without resolved static L3 state

* [ ] When WAN addressing is dynamic, do not emit authoritative runtime `addr4`, `addr6`, static peer or gateway values, or default routes derived from synthetic peers.
* [ ] Keep the interface object itself present in runtime realization.
* [ ] Keep `upstream = "wan"` and interface identity intact.

#### Acceptance criteria

* [ ] CPM runtime WAN interface for DHCP has no fixed IPv4 address.
* [ ] CPM runtime WAN interface for DHCPv6 has no fixed IPv6 address.
* [ ] CPM runtime WAN interface still exists and is renderable.

### 2. Carry inventory-side dynamic WAN metadata into CPM explicitly

* [ ] Preserve inventory-declared WAN addressing mode in `effectiveRuntimeRealization.interfaces.*`.
* [ ] Surface per-family addressing mode in the rendered interface object.
* [ ] Keep this metadata separate from resolved runtime lease state.

#### Acceptance criteria

* [ ] Rendered WAN interface includes explicit metadata like `ipv4.method = "dhcp"` and `ipv6.method = "dhcpv6"`.
* [ ] Rendered WAN interface does not pretend those methods are already resolved addresses.

### 3. Distinguish modeled state from runtime-resolved state

* [ ] Define a CPM contract boundary between model-derived topology and interface identity versus runtime-resolved operational state.
* [ ] Avoid presenting modeled placeholders as resolved runtime truth.
* [ ] Document that DHCP lease results are runtime state, not compile-time state.

#### Acceptance criteria

* [ ] CPM output for dynamic WAN is clearly non-authoritative for live address and gateway assignment.
* [ ] Consumers can tell whether an interface is modeled-static versus runtime-dynamic.

### 4. Treat non-p2p realization links as first-class inventory objects

* [ ] Keep inventory realization support for non-p2p links such as `kind = "wan"`.
* [ ] Ensure p2p coverage validation only applies to p2p transit links.
* [ ] Ensure non-p2p realization links can still back runtime interfaces.

#### Acceptance criteria

* [ ] A WAN runtime port can be realized in inventory without breaking p2p coverage rules.
* [ ] Inventory lint distinguishes p2p transit from WAN attachment correctly.

### 5. Keep internal p2p interfaces intact

* [ ] Do not regress p2p rendering for access to policy, policy to upstream-selector, and core to upstream-selector.
* [ ] Ensure DHCP WAN changes do not leak into transit rendering.

#### Acceptance criteria

* [ ] All existing transit p2p runtime interfaces still render with addresses and routes.
* [ ] Only external dynamic WAN rendering changes.

### 6. Add overlay-aware runtime interface rendering

* [ ] Add explicit rendering support for `kind = "overlay"` runtime interfaces.
* [ ] Preserve overlay identity in runtime realization.
* [ ] Support overlays as upstream-capable interfaces.

#### Acceptance criteria

* [ ] Nebula and WireGuard interfaces can be rendered without being misclassified as WAN.
* [ ] Overlay runtime objects carry overlay metadata explicitly.

### 7. Define CPM output shape for dynamic WAN

* [ ] Decide whether dynamic WAN interfaces should render `addr4 = null`, `addr6 = null`, empty routes, an explicit `addressing` block, and an optional marker like `resolvedAtRuntime = true`.
* [ ] Standardize this across all renderers and consumers.

#### Acceptance criteria

* [ ] Output shape is stable and documented.
* [ ] Consumers do not need to infer dynamic WAN semantics from missing fields alone.

### 8. Add tests for CPM dynamic WAN rendering

* [ ] Add passing tests for DHCP IPv4 WAN render, DHCPv6 WAN render, dual-stack dynamic WAN render, static WAN render, and overlay upstream render.
* [ ] Add assertions that dynamic WAN runtime interfaces retain backing refs, runtime interface name, and upstream identity while dropping static solver-derived L3 state.

### 9. Add regression tests for the current conflict

* [ ] Reproduce the exact current issue where inventory says DHCP or DHCPv6 but CPM still emits static WAN address and routes.
* [ ] Lock in the desired corrected behavior.

#### Acceptance criteria

* [ ] Regression test fails on current buggy behavior.
* [ ] Regression test passes once dynamic WAN rendering is non-authoritative.
