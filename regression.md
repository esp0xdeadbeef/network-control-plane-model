# regression.md

## FS-350 runtime delegated-prefix derivation metadata

- state=solved
- owner: network-control-plane-model
- scope: FS-350-HDS-010-SDS-010-SMS-060 runtime-target and overlay-return route projection
- first-bad-artifact: The 2026-07-17 representative `s-router-prod` pipeline audit found one direct access runtime route and multiple CPM-generated overlay return routes that retained `sourceFile` but dropped `tenant`, `delegatedPrefixLength`, `perTenantPrefixLength`, `slot`, and optional postfix/name derivation fields.
- evidence: `NETWORK_REPO_DIRECT_TEST_OK=1 bash tests/FS-350-HDS-010-SDS-010-SMS-060-runtime-delegated-route-metadata.sh`; the production intent/inventory compile with NFM `af528b2` emitted 22 runtime delegated-route instances with zero missing derivation fields and the expected VLAN2/3/7 slot identities.
- note: CPM now validates complete derivation metadata on direct runtime routes and preserves the same modeled fields on WAN-core and policy-uplink return routes. Missing slot or invalid prefix lengths fail closed without reading the protected prefix source.
