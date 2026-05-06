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
290 src/cpm/resolve-firewall-intent.nix | state=watch | reason=firewall intent now owns per-target NAT and forwarding assembly after rule builders were split into src/cpm/firewall-intent/rules.nix
386 src/cpm/build-site-data.nix | state=watch | reason=site assembly delegates input, overlay endpoint route augmentation, DNS policy, IPAM, runtime targets, advertisements, firewall, and policy binding modules after service and output assembly were split
430 src/cpm/validate-forwarding-model.nix | state=watch | reason=extract schema checks from semantic checks before adding new forwarding-model validation
311 flake.nix | state=watch | reason=flake app wiring remains below hard limit and owns CLI/test entrypoint assembly
<!-- nix-file-loc:end -->

## Architecture Shape

- state=implemented-in-progress | target=Enterprise/Site/Unit/EquipmentModule/ControlModule layout | reason=CPM modules must follow the same responsibility-oriented shape as renderers so site assembly, unit advertisements, realization inventory, and control-plane projection do not collapse into large cross-layer files.
- state=hard-guard | target=`tests/test-structural-keyword-boundary.sh` | reason=Repeated role words (`access`, `policy`, `core`, `upstream-selector`, `downstream-selector`), selector/runtime model words, protocol abbreviations (`p2p`, `bgp`, `dns`, `wan`, `ipam`, `ra`, `pd`, `asn`, `rr`, `vlan`), tenant/service/lane names, generated-name fragments (`link::`, `adj::`, `--access-`, `--uplink-`), parser primitives (`builtins.match`, `builtins.split`, `hasInfix`, `suffixAfter`), and concrete lab identities such as `esp0xdeadbeef` in implementation logic mean files are parsing generated names and lab-specific strings instead of consuming one structured S88-style projection. This hard failure is required because scattered role/site/protocol parsing creates multiple local interpretations of the same CPM output and can miss route families, DNS lanes, BGP rows, or deny-policy rows when the compiled shape changes. Keywords are acceptable as include/import boundaries; other implementation occurrences must be replaced by segmented modules and linear structured data flow.
- state=guard | target=IPv6 parsing and range checks | reason=CPM must use the pinned `lib.network.ipv6` supplied by the `nixpkgs-network` flake override for IPv6 parsing/address math; do not add local IPv6 parsers or 128-bit integer arithmetic.
- state=guard | target=DNS forwarder runtime facts | reason=CPM must reject unresolved DNS placeholder strings before renderer output; runtime/SOPS inventory has to resolve forwarders before control-plane construction.
