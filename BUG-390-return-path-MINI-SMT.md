# BUG: FS-390-HDS-010-SDS-010-SMS-010 does not compile through the CPM (FS-370 guard)

Status: OPEN, filed 2026-11-25 while reconciling the fleet's red CI. NOT caused by
the `policyRoutingSources`/`networkBehavior` change (9155d82): it reproduces with
`finalize.nix` reverted to its parent.

## Symptom

```
$ bash tests/FS-390-HDS-010-SDS-010-SMS-010.sh
error: FS-370-HDS-010-SDS-010-SMS-101: policy/DS per-lane return-path validation
failed: [{"code":"policy-ds-return-path-missing","expectedLane":"client-edge",
"family":4,"interface":"p2p-client-edge-downstream-selector",
"prefix":"198.51.100.10/32","role":"downstream-selector",
"runtimeTarget":"mini-smt-fs-390-hds-010-sds-010-sms-010-downstream-selector"},
{"code":"policy-ds-return-path-missing","expectedLane":"client-edge",...,
"interface":"p2p-downstream-selector-policy--access-client-edge",...,"role":"policy"}]
FAIL FS-390-HDS-010-SDS-010-SMS-010: CPM compileAndBuildFromPaths did not expose forwardingOut
```

## What is established

- The row's own test (`network-labs GAMP/SMT/FS-390-.../test.sh`) now PASSES.
  It is the row's authoritative check and it only needs the NFM.
  Two independent row defects were fixed there (1b15782e in network-labs): a stale
  `source == "ownership.prefixes"` assertion that the classifier stopped emitting
  in network-control-plane-model 68bb6c7, and, in the sibling rows SMS-020/030,
  allow relations with no `returnBehavior`.
- The CPM test compiles through the **managed** inventory that
  `network-labs/scripts/select-current-lab.sh` generates
  (`inventory-s-router-nixos.nix`), not the row's own `inventory-nixos.nix`.
- The guard is per LANE, and requires a `policy-table-internal-reachability`
  return route for every tenant-owned prefix on a lane that carries a policy
  default for that family. `198.51.100.10/32` is the client tenant's **public**
  IPv4 (`ownership.prefixes[].publicIpv4`), so it is in `tenantPrefixOwners`, and
  the `client-edge` lane carries the policy default.

## Why it is not fixed here

There are two defensible repairs and they are a semantics decision, not a typo:

1. the row must model a return path for its own public IPv4 on the client-edge
   lane (a route the row does not declare), or
2. `tenantPrefixOwners` should not contain a tenant's *public* IPv4 -- a public
   address whose traffic is NATed is not a locally routed prefix and needs no
   per-lane return path on the tenant's access lane.

(2) changes what every site routes, so it is a model decision for the owning row
(FS-370/FS-390), not something to guess while clearing a CI red. Filed rather
than guessed.

## Also observed

`FS-390-HDS-010-SDS-010-SMS-030` cannot compile: its two "via-broad-wan"
relations target `{ kind = "public-ipv4"; }`, while the NFM classifies a relation
as broad-WAN only when `to.kind == "external"` with a resolvable uplink
(`network-forwarding-model/implementation/lib/model/public-ipv4-destination-policy/path-policy-helpers.nix -> destinationUplinks`).
So the row models no broad-WAN relation and the NFM emits no
`broadWanDenials` for it. That row is unchanged and still red.
