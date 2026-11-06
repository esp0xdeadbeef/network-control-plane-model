# Remaining CI reds: owner and status

Status: the requester-lane resolver-route blocker is RESOLVED. The remaining reds
are pre-existing module/example migrations.

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

They are module/example migrations outside the DNS requester-lane contract. Each
fails on the pre-change revision as well, so none is a regression of this fix.
