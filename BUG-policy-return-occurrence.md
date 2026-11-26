# BUG: the CPM publishes policy routes without the occurrence a renderer must install

`FS-310-HDS-020-SDS-010-SMS-060` asks a renderer to install "each canonical route into
exactly the context table and lane the canonical record names". For the fabric-internal
return routes that requirement cannot be met from the bundle, because the bundle names the
record but not the interface that installs it — and for the per-lane returns it publishes
no record at all.

## Measured

Fixture: `network-labs/examples/wireguard-provider-overlay`, target
`esp0xdeadbeef-site-a-s-router-policy`.

The bundle publishes exactly one record for `10.20.15.0/24`:

```
{ interface = "p2p-s-router-downstream-selector-s-router-policy--access-s-router-access-admin"
  runtimeIfName = "ens6"
  tableId = 1004
  gateway = "10.10.0.10" }
```

The rendered systemd units carry that prefix on `ens4`, `ens6` and `ens9`, in tables 1002
and 1006 as well:

```
s-router-policy|4|1002|10.20.15.0/24|50  claimed by ens4, ens6, ens9
s-router-policy|4|1006|10.20.15.0/24|50  claimed by ens4, ens6, ens9
```

30 such groups exist for that one container.

## Why the renderer cannot close it alone

Four renderer rules were implemented and each measured against the two rows that matter
(`FS-310-HDS-020-SDS-010-SMS-060` for the duplicates, `FS-540-HDS-010-SDS-010-SMS-040` for
per-lane return routing):

| rule | SMS-060 | FS-540-040 |
| --- | --- | --- |
| keep a derived policy route only if the bundle places it on this interface | PASS | FAIL (sitea_mgmt_wan_dns_v4/v6, sitea_upstream_dns_route) |
| drop when the bundle places it on another interface (rendered-name projection) | FAIL | PASS |
| collapse cross-interface claims on (table, prefix, metric, origin, gateway, preferred source) | PASS | FAIL |
| keep a derived policy route only if the prefix+table exists for this target | FAIL (upstream returns) | FAIL (admin/hostile returns) |

The reason is visible in the data: the per-lane returns (`branch_upstream_branch_return`,
`sitea_admin_wan_return_v4`, `sitea_mgmt_wan_dns_v4`, …) are computed by the renderer
because **no canonical record describes them**. Any rule strict enough to remove the
duplicates also removes them, and any rule lenient enough to keep them leaves the
duplicates.

## What the producer should publish

1. For every policy-table route, the record must name the interface that installs it
   (`runtimeIfName` is already there for the modelled records — the projection into a
   renderer's per-interface map must stay faithful to it, and a record published once must
   not be derived onto a second lane).
2. The per-lane return routes currently derived by the renderer
   (`downstreamSelectorTenantReturnRoutes`, `downstreamSelectorAccessTableTenantReturnRoutes`,
   `policyUpstreamReturnRoutes`, `upstreamCoreReturnRoutes`) must be published as records
   with `policyOnly = true`, `intent.policyTableComplement = true` and their lane facts —
   the CPM already does this for overlay returns in
   `src/cpm/Unit/runtime-targets/overlay-route-augmentation/policy-uplink-returns.nix`;
   the same shape is missing for fabric-internal returns.

Until then the renderer keeps the lenient rule, because deleting a per-lane return breaks
forwarding while leaving a duplicate only violates the presentation invariant.
