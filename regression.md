# regression.md

## FS-260 policy-required access-to-access selector traversal

- state=solved
- owner: network-control-plane-model
- scope: FS-260-HDS-010-SDS-010-SMS-010 default site fabric chain with FS-180 symmetric stateful return
- first-bad-artifact: The 2026-07-17 `s-router-prod` pipeline preserves `allow-vlan2-to-vlan3.returnBehavior = "symmetric"` in NFM and NFM emits `nodePath = [ access-vlan2 downstream-selector policy downstream-selector access-vlan3 ]` with `requiresPolicy = true`. CPM nevertheless emits a direct downstream-selector `access-vlan2 -> access-vlan3` new-flow accept. The NixOS renderer then projects that CPM authority into destination table 1002, so the forward packet bypasses policy while the reply enters policy and is dropped without a matching conntrack entry.
- required-fix: Downstream-selector relation projection must consume the NFM traffic-path authority. An allow relation whose path requires policy may use only the access-to-policy and policy-to-access selector handoffs; it must not emit a direct access-to-access selector rule. Deny rules and explicitly non-policy paths retain their bounded behavior.
- cold-stage finding: After the first fix was pushed and cold-staged, the isolated NixOS live row still dropped the forward IPv4 packet. NFM correctly emitted `nodePath = [ access-source downstream-selector policy downstream-selector access-destination ]`; CPM emitted the second `policy -> access-destination` leg only as a generic `connectionState = "established,related"` selector return. The packet is still the forward half after re-entering the selector from policy and is `new` in that namespace, so the rule cannot authorize it. The first bad artifact remains CPM `forwardingIntent.rules`; the renderer and kernel route both preserve the emitted authority correctly.
- implemented selector fix: Emit a relation-bound new-flow rule for the explicit policy-to-destination-access leg while retaining the stateful-only generic reverse rule. Do not broaden all policy-to-access selector traffic and do not reinstate the direct access-to-access bypass.
- second cold-stage finding: After the relation-bound downstream-selector egress rule was pushed and cold-staged, three isolated IPv4 probes traversed `access-source -> downstream-selector -> policy -> downstream-selector` and arrived on `access-destination.transit`, but `access-destination.dst-lan` transmitted zero packets. NFM still carried the complete relation and final `downstream-selector -> access-destination` path leg. CPM projected that final leg only as the generic access-node `transit -> local` stateful return rule, so the forward packet was again rejected as `new`. The renderer and kernel selected the modeled destination LAN correctly; the first bad artifact is CPM access-node `forwardingIntent.rules`.
- implemented access fix: Consume the explicit NFM destination path leg on the owning access-node and emit a relation-scoped `transit -> destination-local` new-flow rule. Preserve the generic stateful return rule, require an allow relation whose modeled path actually terminates on that access-node, retain modeled traffic matches and source prefixes, and emit nothing for deny or unrelated paths.
- evidence: `NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/FS-260-HDS-010-SDS-010-SMS-010-policy-required-access-to-access.sh`; the focused seeded-negatives prove the direct selector accept is absent only for policy-required allow paths, both relation-bound forward handoffs exist, the destination access ingress retains source prefixes, the generic reverse remains stateful, and deny, wrong-destination, and wrong-path inputs emit no new-flow ingress. `TEST_JOBS=42 NETWORK_REPO_DIRECT_TEST_OK=1 ./run-all-tests.sh` passes 222/222 tests on commit `5029a38f9feed2f97d855a7425e66b797787824e`.
- live-boundary: Closed after a cold offline-to-new-boot stage on isolated VLANs only. `scripts/smt-live-FS-260-HDS-010-SDS-010-SMS-010.sh --live` passes NixOS and CLAB dual-stack forward/return probes, reverse-new-flow denial, and policy-interface counter deltas. Production VLAN2/VLAN3 was not used.

## FS-860 explicit DHCP lease-state path

- state=solved
- owner: network-control-plane-model
- scope: FS-860-HDS-010-SDS-010-SMS-030 explicit DHCP and DHCPv6 lease-state paths
- first-bad-artifact: The 2026-07-17 `s-router-prod` candidate supplied only persistence root `/var/lib/kea`, so CPM emitted `/var/lib/kea/dhcp4/<runtime-target>/<tenant>` for VLAN2/3/7 and provided no way for inventory to select the existing lease database paths.
- evidence: `NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/test-fs860-hds010-sds010-sms030-explicit-dhcp-lease-state-path.sh`; the current `network-labs/examples/single-wan` pipeline preserves explicit IPv4 `/var/lib/kea/client.leases` and IPv6 `/var/lib/kea/client-v6.leases` paths exactly from inventory advertisements into their persistence contracts, while an empty explicit path fails at the exact inventory field.
- note: Inventory owns an optional concrete lease storage location. CPM validates and preserves it; entries without it retain the deterministic persistence-root fallback.

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
- adjacent regression: Scoping an external-to-service endpoint to its owning access lane applies only when the relation carries `publicIngressTupleAuthority`. Named non-public fabrics such as east-west retain their explicit service projection; otherwise existing service ingress routes and firewall tuples disappear. The renderer `test-policy-service-ingress-routes.sh` is the cross-repository regression predicate.

## FS-525 / FS-540 reproducible core DNS realization

- state=open
- owner: network-control-plane-model
- scope: FS-525-HDS-010-SDS-010-SMS-010 and FS-540-HDS-010-SDS-010-SMS-010 through SMS-045
- first-bad-artifact: The 2026-07-18 `s-router-prod` audit found that `dns-policy/derived-services/context.nix` classifies every DNS service with a provider as hosted on every DNS listener. CPM consequently combines access-resolver semantics and their public default forwarders with the core listener, even though the input names `core-dns` on provider node `core` and requires full recursion without public forwarders or fallback. The same pipeline ignores the declared local-only VLAN3 to VLAN2 namespace boundary, so the NixOS consumer currently needs DNS projection overrides.
- required-fix: Join each named DNS service to its explicit realized provider node and consume the compiler/NFM recursive and local-sharing contracts. Emit internal-only core listeners, named dual-stack access-to-core forwarders, deterministic egress binding, and source-scoped local-only/refuse-non-local policy without inventing addresses or public fallback. Preserve privacy-safe fail-closed warnings for missing, ambiguous, unstable, family-incomplete, or renderer-divergent authority.
- implemented FS-525 boundary: CPM now preserves the normalized DNS contract, joins `core-dns` to its explicit provider runtime target, derives both service families from the realized model loopback, and emits access upstream records, core listeners, symmetric policy inputs, and one explicitly selected core DNS egress. A second modeled egress is not selected by order. Legacy inventory-owned cross-scope services remain fail-closed when their endpoint is absent. FS-540 local-sharing and renderer consumption remain open.
- FS-525 evidence: `NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/FS-525-HDS-010-SDS-010-SMS-010-named-core-resolver-binding.sh`; `TEST_JOBS=42 NETWORK_REPO_DIRECT_TEST_OK=1 ./run-all-tests.sh` passes 223/223 tests. The focused row uses the pushed isolated `network-labs` five-node topology, contains no resolver address in intent or inventory, and proves no public fallback plus exact `isp-primary` selection while `overlay-secondary` is also modeled.
- evidence: Add focused CPM tests over the FS-525/FS-540 lab source. Seeded negatives must prove that core receives no access-service public forwarders, VLAN3 cannot borrow recursion or transitive egress, and multi-core/multi-egress ambiguity produces stable modeled-ID warnings rather than order-dependent selection.
