#!/usr/bin/env bash
# GAMP-ID: FS-525-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
cd "$repo_root"

expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  system = builtins.currentSystem;
  labs = flake.inputs.network-labs.outPath;
  built = flake.libBySystem.${system}.compileAndBuildFromPaths {
    inputPath = labs + "/GAMP/SMT/FS-525-HDS-010-SDS-010-SMS-010/intent.nix";
    inventoryPath = labs + "/GAMP/SMT/FS-525-HDS-010-SDS-010-SMS-010/inventory-nixos.nix";
  };
  site = built.control_plane_model.data.mini-smt."FS-525-HDS-010-SDS-010-SMS-010";
  forwardingSite = built.forwardingOut.enterprise.mini-smt.site."FS-525-HDS-010-SDS-010-SMS-010";
  targetFor = logicalName:
    builtins.head (
      builtins.filter
        (target: (target.logicalNode.name or null) == logicalName)
        (builtins.attrValues site.runtimeTargets)
    );
  serviceFor = serviceName:
    builtins.head (builtins.filter (service: service.name == serviceName) site.services);
  stripPrefix = value: builtins.head (builtins.match "([^/]+)/.*" value);
  coreNode = forwardingSite.nodes."core-primary";
  core4 = stripPrefix coreNode.loopback.ipv4;
  core6 = stripPrefix coreNode.loopback.ipv6;
  access = targetFor "access-dns";
  core = targetFor "core-primary";
  accessDns = access.services.dns;
  accessUpstream = builtins.head accessDns.upstreamResolvers;
  coreDns = core.services.dns;
  coreEgressRules = builtins.filter
    (rule: (rule.intent.kind or null) == "dns-service-public-egress")
    (core.forwardingIntent.rules or [ ]);
  coreService = serviceFor "core-dns";
  relation = builtins.head (
    builtins.filter
      (entry: entry.id == "FS-525-HDS-010-SDS-010-SMS-010__access-dns-to-core-dns")
      site.communicationContract.allowedRelations
  );
  relationRules = builtins.concatLists (builtins.map
    (target: builtins.filter
      (rule: (rule.relationId or null) == relation.id)
      (target.forwardingIntent.rules or [ ]))
    (builtins.attrValues site.runtimeTargets));
in
  site.dns == forwardingSite.dns
  && (site.dns.warnings or [ ]) == [ ]
  && coreService.providerEndpoints == [ { name = "core-primary"; ipv4 = [ core4 ]; ipv6 = [ core6 ]; } ]
  && coreService.preferredUplinks == [ "isp-primary" ]
  && accessUpstream.addresses == [ core4 core6 ]
  && accessUpstream.service == "core-dns"
  && accessUpstream.node == "core-primary"
  && !(builtins.any
    (address: builtins.elem address [ "1.1.1.1" "9.9.9.9" "2606:4700:4700::1111" "2620:fe::fe" ])
    (accessDns.forwarders or [ ]))
  && coreDns.listen == [ core4 core6 ]
  && (coreDns.forwarders or [ ]) == [ ]
  && coreDns.recursionMode == "iterative"
  && coreDns.egress.uplinks == [ "isp-primary" ]
  && core.runtimeOriginEgress.uplinks == [ "isp-primary" ]
  && coreEgressRules != [ ]
  && builtins.all (rule: rule.toInterface == "wan0") coreEgressRules
  && relation.returnBehavior == "symmetric"
  && builtins.any (rule: (rule.direction or null) == "relation-forward") relationRules
  && builtins.any (rule: (rule.direction or null) == "relation-reverse") relationRules
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS FS-525 named core resolver binding"
else
  echo "FAIL FS-525 named core resolver binding" >&2
  exit 1
fi
