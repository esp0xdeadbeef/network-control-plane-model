# Remaining CI reds: owner, contract, and blocker

Status: BLOCKED on an upstream contract that does not exist yet.

The FS-540 named-core family is green (listener/forwarder = emitted relation
endpoint, FS-540-HDS-010-SDS-010-SMS-020/035). The reds below share one missing
upstream artifact: a requester-lane service-route leg for a resolver endpoint
that the forwarding model does not emit, so the control plane cannot project it
without re-deriving upstream authority (FS-171: consumers import, never
re-derive).

- `test-dns-service-policy-routes` (client lane learns the resolver endpoint):
  the resolver's own lane carries `10.20.10.1/32` (`service-endpoint-reachability`,
  relation identity, policy-table provenance), but no requester-lane leg exists.
  FS-540 SMS-020 requires "relation-owned requester-lane route authority
  containing policy table, outgoing lane, selected next-hop identity, and
  provenance for each requested family and resolver endpoint prefix". The
  requester leg is a forwarding-model relation-path output; CPM must not invent
  the next hop.
- `test-sitec-overlay-service-ingress`, `test-s-router-hetz-overlay-dns-ingress`,
  `test-example-overlay-upstream-policy-defaults-preserved`,
  `test-preferred-uplink-defaults`, `FS-460-HDS-010-SDS-010-SMS-050`: same chain
  (delegated/overlay default lane binding plus requester-lane service routes).
- `FS-500-040`, `FS-800-*`, `FS-970-040`, `FS-260-015`, `FS-310-120`,
  `FS-380-050`, `FS-410-030`, `FS-420-030`, `FS-720-030`, `FS-740-010`,
  `FS-770-010`: pre-existing module/example migrations, all reproduced against
  the pre-change revision (git worktree at 64ec24f^), i.e. not regressions of
  the FS-540 fix.

Why this is blocked rather than incomplete: AGENTS requires the requirement to
be fixed in URS/FS first, in the same change, before implementation
("ADD OR FIX THE REQUIREMENT IN THE URS/FS FIRST, in the same change, with the
descriptive-category sentence - then implement against it"). The authoritative
FS/SMS text lives in `network-codex-agent`, which the operator explicitly
excluded from this run ("codex-agent can be skipped"); it is also the only
repository that owns the forwarding-model requirement for the missing leg.
Implementing the leg in CPM instead would place forwarding meaning in the wrong
layer (network-layer discipline in AGENTS) and violate FS-171.

Unblocking requires one of:

1. permission to edit `network-codex-agent` GAMP (FS-540 SMS-020 / FS-310
   forwarding-model requirement) plus the forwarding-model emission, or
2. confirmation that the requester-lane resolver leg is already emitted
   upstream and that this repository is simply not consuming it.
