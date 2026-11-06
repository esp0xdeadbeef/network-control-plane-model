# Remaining CI reds: owner and status

Status: both contract blockers recorded earlier are RESOLVED (requester-lane
resolver reachability, and the policy-lane selected-exit default). The remaining
reds are pre-existing module/example migrations.

## Resolved: requester-lane resolver service route

FS-540-HDS-010-SDS-010-SMS-020 requires "relation-owned requester-lane route
authority containing policy table, outgoing lane, selected next-hop identity, and
provenance for each requested family and resolver endpoint prefix", and
FS-540-HDS-010-SDS-010-SMS-040 defines the requester-lane keying that consumes
it. Both are control-plane-model responsibilities, not forwarding-model ones:
the inputs are already modelled (admitted relation, resolver endpoint,
requester lane, next hop), so emitting the requester leg here materializes
existing authority (URS "Only modeled authority can create network behavior",
"Realization data may bind already-modeled authority"), and does not re-derive
upstream meaning (FS-171).

`dns-service-routes.nix` now emits the emitted endpoint prefix on the requester
leg's own downstream access lane, with the relation identity, policy-table
complement and the lane's modelled next hop. It is not emitted on exit/uplink
lanes (FS-550 leak prevention), not fanned out to sibling access lanes the
relation did not admit (SMS-040), and never duplicated against the
destination-facing pass (FS-315).

Covered by `test-dns-service-policy-routes` (requester-lane authority, admitted
dmz lane, non-admitted streaming lane, policy-table provenance),
`test-runtime-origin-loopback-egress` (no return route on access-uplink lanes),
and `test-network-labs-inventory-sweep` (21 outputs, no duplicate routes).

## Remaining reds (pre-existing, reproduced on 64ec24f^)

`FS-260-HDS-010-SDS-010-SMS-015`, `FS-310-HDS-010-SDS-010-SMS-120`,
`FS-380-HDS-020-SDS-010-SMS-050`, `FS-410-HDS-010-SDS-010-SMS-030`,
`FS-420-HDS-010-SDS-010-SMS-030`, `FS-460-HDS-010-SDS-010-SMS-050`,
`FS-500-HDS-010-SDS-010-SMS-040`, `FS-720-HDS-030-SDS-010-SMS-010`,
`FS-740-HDS-010-SDS-010-SMS-010`, `FS-770-HDS-010-SDS-010-SMS-010`,
`FS-800-HDS-010-SDS-010-SMS-010`, `FS-800-HDS-010-SDS-012-SMS-010`,
`FS-800-HDS-030-SDS-020-SMS-020`, `FS-970-HDS-010-SDS-020-SMS-040`,
`test-example-overlay-upstream-policy-defaults-preserved`,
`test-preferred-uplink-defaults`, `test-sitec-overlay-service-ingress`,
`test-s-router-hetz-overlay-dns-ingress`.

The full suite is 224 PASS / 18 FAIL. Every one of these 18 also fails on the
pre-change revision `64ec24f^` (that revision had 20; `FS-525-HDS-010-SDS-010-SMS-010`
and `test-dns-service-policy-routes` are the two this run moved to PASS), so none
is a regression of the DNS work.

Resolved: `policy-lane-defaults.nix` now complements each policy access-uplink
lane with the default its peer end of the same modeled `link::` carries, using
the lane's on-link peer address, and only when the modeled runtime-origin source
relation for that lane exists (FS-550: route by source, not by a broad default).
`test-preferred-uplink-defaults` asserts the resulting per-lane parity, and
`test-runtime-origin-loopback-egress` asserts the source-routing condition.
FS-315 lane hygiene keeps the lane-less duplicate out of the main table and the
renderer maps the canonical `table` field to systemd `Table`.
