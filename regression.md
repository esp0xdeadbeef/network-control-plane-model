# network-control-plane-model Regression Notes

This file records current policy exceptions only. Keep entries exact and
current; do not use it as a session log.

## Nix File LOC States

The file-size guard requires every tracked Nix file over the soft limit to have
a current state and reason. Files at or above the hard limit fail immediately
and must be split before tests can pass.

<!-- nix-file-loc:start -->
483 invariants/default.nix | state=watch | reason=invariant entrypoint still coordinates forwarding-model input checks and CPM output checks after shared assertion helpers were extracted
480 src/cpm/resolve-policy-endpoint-bindings.nix | state=watch | reason=extract relation endpoint parsing from runtime binding projection before adding new policy behavior
333 src/cpm/resolve-firewall-intent.nix | state=watch | reason=split per-family NAT target assembly from forwarding-entry wiring before adding more firewall behavior
411 src/cpm/build-site-data.nix | state=watch | reason=split route-augmentation orchestration, runtime-target construction, default-reachability assembly, and output projection into separate Site build modules before adding more site orchestration
430 src/cpm/validate-forwarding-model.nix | state=watch | reason=extract schema checks from semantic checks before adding new forwarding-model validation
311 flake.nix | state=watch | reason=flake app wiring remains below hard limit and owns CLI/test entrypoint assembly
250 src/cpm/Site/default-reachability/route-synthesis.nix | state=watch | reason=split overlay delegated egress synthesis from final default-route classification before adding more default reachability behavior
247 src/cpm/Site/default-reachability/source-selection.nix | state=watch | reason=split default-source detection from delegated runtime-prefix owner classification before adding more route-source classes
218 src/cpm/ControlModule/dns-policy/derived-services.nix | state=watch | reason=split DNS access/egress derivation helpers before adding more DNS service policy behavior
216 src/cpm/ControlModule/route-augmentation/service-ingress.nix | state=watch | reason=split service endpoint selection from external ingress route projection before adding more service-ingress behavior
<!-- nix-file-loc:end -->

## Architecture Shape

- state=implemented-in-progress | target=Enterprise/Site/Unit/EquipmentModule/ControlModule layout | reason=CPM modules must follow the same responsibility-oriented shape as renderers so site assembly, unit advertisements, realization inventory, and control-plane projection do not collapse into large cross-layer files.
- state=hard-guard | target=`tests/test-structural-keyword-boundary.sh` | reason=Repeated role words (`access`, `policy`, `core`, `upstream-selector`, `downstream-selector`), selector/runtime model words, protocol abbreviations (`p2p`, `bgp`, `dns`, `wan`, `ipam`, `ra`, `pd`, `asn`, `rr`, `vlan`), tenant/service/lane names, generated-name fragments (`link::`, `adj::`, `--access-`, `--uplink-`), parser primitives (`builtins.match`, `builtins.split`, `hasInfix`, `suffixAfter`), and concrete lab identities such as `esp0xdeadbeef` in implementation logic mean files are parsing generated names and lab-specific strings instead of consuming one structured S88-style projection. This hard failure is required because scattered role/site/protocol parsing creates multiple local interpretations of the same CPM output and can miss route families, DNS lanes, BGP rows, or deny-policy rows when the compiled shape changes. Keywords are acceptable as include/import boundaries; other implementation occurrences must be replaced by segmented modules and linear structured data flow.
- state=guard | target=IPv6 parsing and range checks | reason=CPM must use the pinned `lib.network.ipv6` supplied by the `nixpkgs-network` flake override for IPv6 parsing/address math; do not add local IPv6 parsers or 128-bit integer arithmetic.
- state=guard | target=DNS forwarder runtime facts | reason=CPM must reject unresolved DNS placeholder strings before renderer output; runtime/SOPS inventory has to resolve forwarders before control-plane construction.
- state=verified-passing | target=`tests/test-network-labs-inventory-sweep.sh` | reason=The locked sweep compiles every network-labs example plus lab-sigma NixOS/CLAB inventories and checks DNS, BGP, policy, route, shape, and service-provider endpoint contracts across 46 outputs.
- state=fixed-locally | target=policy deny, BGP advertisement, router-self DNS, and DNS access route contracts | reason=Policy targets emit relation-derived deny rows, BGP access routers emit explicit `bgp.networks.ipv4`/`ipv6`, explicit access advertisements that publish router-self DNS become Unbound service contracts, and access DNS services emit route-contract plus exact P2P route rows for modeled forwarders so renderers do not infer policy, advertisements, or DNS paths.
- state=fixed-locally | target=DNS public resolver egress class derivation | reason=DNS services with intent-derived tenant/service DNS-to-external allowance now carry `explicit-egress-default`; the jq report also distinguishes explicit `false` from missing fallback policy instead of treating `false // true` as allowed fallback.
- state=fixed-locally | target=delegated IPv6 public-egress defaults | reason=Delegated IPv6 access lanes now strip non-overlay `::/0` defaults while preserving non-delegated WAN defaults and core underlay defaults.
- state=fixed-locally | target=site-c overlay-ingress delegated IPv6 public egress | reason=Runtime-routed IPv6 tenant prefixes now cause CPM to place a policy-only delegated-public-egress default on the upstream selector overlay-core ingress toward the owning tenant east-west policy lane, preventing no-route failures after Nebula decapsulation while keeping the policy lane from becoming a second default source.
- state=fixed-locally | target=S88 policy-router firewall projection | reason=Policy firewall projection now maps modeled service endpoints onto same-access policy uplink lanes, so relation-derived service denies become explicit `forwardingIntent.rules` instead of disappearing before renderer tests.
- state=still-broken | target=Nebula overlay provider contract | reason=`tests/test-nebula-overlays-have-provider-contract.sh` proves some examples emit overlays with `provider = "nebula"` but no provider-specific `nebula` contract, which already makes the Nebula renderer fail on `single-wan-with-nebula`, `single-wan-with-nebula-any-to-any-fw`, and `overlay-east-west`; either CPM must normalize this provider contract or the upstream model must emit the missing provider surface.
- state=fixed-locally | target=transit-role default route classification | reason=CPM now marks synthesized default routes on policy/upstream-selector/downstream-selector roles as `policyOnly = true`, so lane defaults are rendered through policy routing instead of relying on renderer-side main-table defaults. `tests/test-transit-default-routes-are-classified.sh` now requires this for the focused prod-risk examples.
