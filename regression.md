# regression.md

## FS-350 runtime delegated-prefix derivation metadata

- state=solved
- owner: network-control-plane-model
- scope: FS-350-HDS-010-SDS-010-SMS-060 runtime-target and overlay-return route projection
- first-bad-artifact: The 2026-07-17 representative `s-router-prod` pipeline audit found one direct access runtime route and multiple CPM-generated overlay return routes that retained `sourceFile` but dropped `tenant`, `delegatedPrefixLength`, `perTenantPrefixLength`, `slot`, and optional postfix/name derivation fields.
- evidence: `NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/FS-350-HDS-010-SDS-010-SMS-060-runtime-delegated-route-metadata.sh`; the production intent/inventory compile with NFM `af528b2` emitted 22 runtime delegated-route instances with zero missing derivation fields and the expected VLAN2/3/7 slot identities.
- note: CPM now validates complete derivation metadata on direct runtime routes and preserves the same modeled fields on WAN-core and policy-uplink return routes. Missing slot or invalid prefix lengths fail closed without reading the protected prefix source.

## FS-310 production public-ingress tuple realization

- state=solved
- owner: network-control-plane-model
- scope: FS-310-HDS-020-SDS-010-SMS-075 tuple-owned DNAT, forward, source-rewrite, target-route, and per-hop return realization
- first-bad-artifact: The 2026-07-17 `s-router-prod` audit found that NFM and CPM preserve `allow-wan-to-s-nebula-container.publicIngressTupleAuthority` and CPM resolves the provider endpoint addresses, but the core `natIntent` contains only internet-egress translation records. It has no tuple-owned public-ingress realization, while the downstream renderer emits zero native DNAT rules.
- evidence: The NixOS profile must currently remove two unrelated broad `ppp0`/`wan` to `ens3` reverse accepts and inject DNAT, source rewrite, exact forwarding, and return routes through `nebula-public-ingress-hotpatch.nix`.
- verification: `NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/test-fs310-hds020-sds010-sms075-public-ingress-runtime-path.sh`; the production `s-router-prod` compile emitted one native NAPT record, exact TCP/UDP 4242 forwarding scoped to the target `/32` on all four post-DNAT namespaces, target and source-return routes, and no unrelated VLAN2/VLAN7 public-ingress rule.
- full-suite context: the parallel candidate sweep passed 127/220 tests; the predecessor baseline was 126/219, so the added FS-310 test accounts for the pass delta while the existing 93-fixture debt remains outside this regression (predominantly pre-FS-180 allow fixtures without explicit `returnBehavior`, active-lab selection assumptions, and adjacent-repository worktree assumptions).
- note: CPM must project the explicit public-ingress authority into the owning core and route path. The renderer shall consume that projection; it shall not rediscover the target through an inventory side channel, and the host profile shall not invent policy.
