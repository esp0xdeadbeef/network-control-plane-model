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

- Tests: implemented
  - negative fixture omitting exactly one required lane binding must hard-fail.

## Overlay Provisioning Output (Nebula / WireGuard / etc.)

Status: implemented.

Goal: when intent defines overlays, emit a renderer-consumable list of:

- which logical nodes terminate each overlay (and therefore must be provisioned)
- which overlay IP(s) those termination nodes should use

Proposed inventory contract (technique-specific data belongs here, not in compiler/forwarding-model):

- `inventory.controlPlane.sites.<enterprise>.<site>.overlays.<overlayName>.provider = "nebula" | "wireguard" | ...` (optional)
- `inventory.controlPlane.sites.<enterprise>.<site>.overlays.<overlayName>.ipam.ipv4.prefix = "<cidr>"` (optional; deterministic per-site allocator)
- `inventory.controlPlane.sites.<enterprise>.<site>.overlays.<overlayName>.ipam.ipv6.prefix = "<cidr>"` (optional; deterministic per-site allocator)
- `inventory.controlPlane.sites.<enterprise>.<site>.overlays.<overlayName>.nodes.<nodeName>.addr4/addr6 = "<cidr>"` (optional; explicit per-node addresses)
- `inventory.controlPlane.sites.<enterprise>.<site>.overlays.<overlayName>.nebula = { ... }` (optional; opaque to CPM)

CPM output contract:

- `control_plane_model.data.<enterprise>.<site>.overlays.<overlayName> = { terminateOn = [ "<node>" ... ]; nodes.<node>.addr4/addr6; provider/... }`

Notes:

- The forwarding-model already owns overlay reachability and termination semantics (e.g. `overlayReachability`).
- The CPM should only join those semantics with inventory-provided provisioning inputs and emit explicit output.

## IPv6 GUA / Prefix Delegation (PD) Distribution

Status: deterministic PD planning is implemented in CPM output. Renderers still need to consume it.

Problem: if a core WAN receives a delegated prefix (dynamic), tenant-facing segments still need deterministic,
auditable IPv6 prefixes and advertisement behavior.

Proposed approach:

- Inventory declares WAN IPv6 upstream method as PD-capable, plus PD constraints:
  - `inventory.deployment.hosts.<host>.uplinks.<uplink>.ipv6.method = "dhcpv6-pd"`
  - `...ipv6.pd = { delegatedPrefixLength = 56; perTenantPrefixLength = 64; }`

- Inventory declares per-tenant IPv6 behavior (not forwarding semantics):
  - `inventory.controlPlane.sites.<enterprise>.<site>.tenants.<tenant>.ipv6.mode = "slaac" | "dhcpv6" | "static"`
  - For `static`, inventory supplies `prefixes = [ "<prefix>/64" ... ]`.

- CPM output:
  - emits `tenantIPv6.prefixes` (resolved static or PD-derived slots) plus per-tenant advertisement mode
  - emits a stable, deterministic tenant prefix allocation plan from the delegated prefix (when PD is used),
    using a documented ordering (e.g. sorted tenant names) and a strict collision check.

Renderer expectations:

- Renderers must not invent PD allocation, SLAAC/DHCPv6 behavior, or RA flags.
- Renderers consume explicit `tenantIPv6` outputs to configure RA/DHCPv6 (and route/firewall policies) deterministically.

Remaining work:

- Renderers:
  - consume `control_plane_model.data.<enterprise>.<site>.ipv6` PD plan to configure RA / DHCPv6 without guessing.
- Tests:
  - add renderer-side offline assertions (no VM boot) that validate emitted RA/DHCPv6 config matches CPM output.
