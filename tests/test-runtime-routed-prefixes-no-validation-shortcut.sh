#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
violations_tsv="${tmp_dir}/violations.tsv"

nix flake archive --json "path:${repo_root}" >"${archive_json}"
labs_root="$(jq -er '.inputs["network-labs"].path' "${archive_json}")"
examples_root="${labs_root}/examples"

: >"${violations_tsv}"

while IFS= read -r -d '' inventory_path; do
  example_dir="$(dirname "${inventory_path}")"
  rel_inventory="${inventory_path#"${labs_root}/"}"

  CASE_DIR="${example_dir}" INVENTORY_PATH="${inventory_path}" REL_INVENTORY="${rel_inventory}" nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --json --expr '
      let
        caseDir = builtins.getEnv "CASE_DIR";
        inventoryPath = builtins.getEnv "INVENTORY_PATH";
        relInventory = builtins.getEnv "REL_INVENTORY";

        attrsOrEmpty = value: if builtins.isAttrs value then value else { };
        listOrEmpty = value: if builtins.isList value then value else [ ];
        concatMapAttrs = f: attrs:
          builtins.concatLists (builtins.attrValues (builtins.mapAttrs f (attrsOrEmpty attrs)));
        attrNames = attrs: builtins.attrNames (attrsOrEmpty attrs);
        hasPrefix = prefix: value:
          builtins.substring 0 (builtins.stringLength prefix) value == prefix;
        normalizeSource = value:
          if !builtins.isString value then null
          else if hasPrefix "/run/secrets/" value || hasPrefix "/run/" value then value
          else "/run/secrets/${value}";
        load = path:
          let value = import path;
          in if builtins.isFunction value then value { } else value;

        intent = load "${caseDir}/intent.nix";
        inventory = load inventoryPath;

        intentSites =
          if (intent.controlPlane or { }) ? enterprises then
            builtins.mapAttrs (_enterpriseName: enterprise: enterprise.sites or { }) intent.controlPlane.enterprises
          else if (intent.controlPlane or { }) ? sites then
            intent.controlPlane.sites
          else
            intent;

        intentRouted =
          concatMapAttrs
            (enterpriseName: enterprise:
              concatMapAttrs
                (siteName: site:
                  builtins.concatMap
                    (prefix:
                      builtins.map
                        (routedPrefix: {
                          inherit enterpriseName siteName;
                          tenantName = prefix.name or null;
                          name = routedPrefix.name or null;
                          family = routedPrefix.family or null;
                          allocation = routedPrefix.allocation or null;
                        })
                        (listOrEmpty (prefix.routedPrefixes or [ ])))
                    (listOrEmpty (site.ownership.prefixes or [ ])))
                enterprise)
            intentSites;

        inventoryRouted =
          concatMapAttrs
            (enterpriseName: enterprise:
              concatMapAttrs
                (siteName: site:
                  concatMapAttrs
                    (tenantName: tenant:
                      builtins.concatMap
                        (prefixName:
                          let
                            routed = attrsOrEmpty tenant.routedPrefixes.${prefixName};
                            hasSemanticFields =
                              routed ? sourceFile
                              || routed ? delegatedPrefixLength
                              || routed ? perTenantPrefixLength
                              || routed ? slot
                              || routed ? prefixPostfix;
                          in
                          if hasSemanticFields then
                            [
                              {
                                inherit enterpriseName siteName tenantName;
                                name = prefixName;
                                sourceFile = normalizeSource (routed.sourceFile or null);
                              }
                            ]
                          else
                            [ ])
                        (attrNames (tenant.routedPrefixes or { })))
                    (site.tenants or { }))
                enterprise)
            (inventory.controlPlane.sites or { });

        inventorySemanticLeak =
          builtins.map
            (entry: {
              status = "inventory-routed-prefix-semantic-leak";
              inventory = relInventory;
              routedPrefix = "${entry.enterpriseName}.${entry.siteName}.${entry.tenantName}.${entry.name}";
              detail = "runtime IPv6 routed-prefix semantics must live in intent, not inventory tenant routedPrefixes";
            })
            inventoryRouted;

        externalValidationShortcuts =
          concatMapAttrs
            (nodeName: node:
              let
                ext = attrsOrEmpty (node.externalValidation or { });
                adsExt = attrsOrEmpty ((attrsOrEmpty (node.advertisements or { })).externalValidation or { });
                hasShortcut =
                  (ext.delegatedIPv6Prefix or false) == true
                  || (adsExt.delegatedIPv6Prefix or false) == true
                  || (ext.delegatedPrefixSecretName or "") != ""
                  || (adsExt.delegatedPrefixSecretName or "") != "";
              in
                if hasShortcut then
                  [
                    {
                      status = "external-validation-delegated-prefix-shortcut";
                      inventory = relInventory;
                      routedPrefix = nodeName;
                      detail = "delegated public IPv6 prefix must be modeled as tenant routedPrefixes, not node externalValidation";
                    }
                  ]
                else
                  [ ])
            ((attrsOrEmpty (inventory.realization or { })).nodes or { });
      in
        inventorySemanticLeak ++ externalValidationShortcuts
    ' | jq -r '.[] | [.status, .inventory, .routedPrefix, .detail] | @tsv' >>"${violations_tsv}"
done < <(find "${examples_root}" -mindepth 2 -maxdepth 2 \( -name 'inventory.nix' -o -name 'inventory-clab.nix' -o -name 'inventory-nixos.nix' \) -print0 | sort -z)

if [[ -s "${violations_tsv}" ]]; then
  echo "FAIL runtime-routed-prefixes-no-validation-shortcut: bad runtime IPv6 routed-prefix modeling in network-labs examples" >&2
  column -t -s "$(printf '\t')" "${violations_tsv}" >&2
  exit 1
fi

bgp_output="${tmp_dir}/s-router-overlay-dns-lane-policy.json"
static_output="${tmp_dir}/ipv6-pd-downstream-delegation.json"

nix run --show-trace "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${examples_root}/s-router-overlay-dns-lane-policy/intent.nix" \
  "${examples_root}/s-router-overlay-dns-lane-policy/inventory-nixos.nix" \
  "${bgp_output}" >/dev/null

nix run --show-trace "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${examples_root}/ipv6-pd-downstream-delegation/intent.nix" \
  "${examples_root}/ipv6-pd-downstream-delegation/inventory-nixos.nix" \
  "${static_output}" >/dev/null

check_result="$(
  BGP_OUTPUT="${bgp_output}" STATIC_OUTPUT="${static_output}" nix eval \
  --extra-experimental-features 'nix-command flakes' \
  --impure --expr '
    let
      bgpData = builtins.fromJSON (builtins.readFile (builtins.getEnv "BGP_OUTPUT"));
      staticData = builtins.fromJSON (builtins.readFile (builtins.getEnv "STATIC_OUTPUT"));

      bgpAccess =
        bgpData.control_plane_model.data.espbranch."site-b"
          .runtimeTargets."espbranch-site-b-b-router-access-hostile";
      bgpCore =
        bgpData.control_plane_model.data.espbranch."site-b"
          .runtimeTargets."espbranch-site-b-b-router-core-nebula";
      bgpRa = builtins.head bgpAccess.advertisements.ipv6Ra;
      bgpRuntimePrefixes = bgpAccess.bgp.networks.routedPrefixes.ipv6 or [ ];
      bgpCoreUpstreamRoutes =
        bgpCore.effectiveRuntimeRealization.interfaces."p2p-b-router-core-nebula-b-router-upstream-selector".routes.ipv6 or [ ];

      staticSite = staticData.control_plane_model.data.esp0xdeadbeef."site-a";
      staticAccess = staticSite.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-client-b";
      staticRa = builtins.head staticAccess.advertisements.ipv6Ra;
      staticReturnRoutes =
        builtins.concatLists (
          builtins.concatMap
            (targetName:
              let target = staticSite.runtimeTargets.${targetName};
              in builtins.map
                (ifName: ((target.effectiveRuntimeRealization.interfaces.${ifName} or { }).routes.ipv6 or [ ]))
                (builtins.attrNames (target.effectiveRuntimeRealization.interfaces or { })))
            (builtins.attrNames staticSite.runtimeTargets)
        );
      staticP2pGuaAddrs =
        builtins.concatLists (
          builtins.concatMap
            (targetName:
              let target = staticSite.runtimeTargets.${targetName};
              in builtins.concatMap
                (ifName:
                  let
                    iface = target.effectiveRuntimeRealization.interfaces.${ifName};
                    addr6 = iface.addr6 or iface.ipv6 or null;
                    isGua = builtins.isString addr6 && !(builtins.substring 0 2 addr6 == "fd");
                  in
                  if (iface.kind or null) == "p2p" && isGua then [ "${targetName}.${ifName}.${addr6}" ] else [ ])
                (builtins.attrNames (target.effectiveRuntimeRealization.interfaces or { })))
            (builtins.attrNames staticSite.runtimeTargets)
        );

      hasPrefixBySource = sourceFile: prefixes:
        builtins.any
          (prefix:
            (prefix.family or null) == "ipv6"
            && (prefix.sourceFile or null) == sourceFile)
          prefixes;
      hasRuntimePrefixReturnRoute = sourceFile: routes:
        builtins.any
          (route:
            (route.sourceFile or null) == sourceFile
            && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return"
            && ((route.intent or { }).source or null) == "intent-routed-prefix"
            && ((route.intent or { }).accessNode or null) == "b-router-access-hostile"
            && (route.via6 or null) == "fd42:dead:feed:1000:0:0:0:5")
          routes;
      hasStaticReturnRoute = targetNode: sourceFile:
        builtins.any
          (route:
            (route.sourceFile or null) == sourceFile
            && ((route.intent or { }).kind or null) == "runtime-routed-prefix-return"
            && ((route.intent or { }).source or null) == "intent-routed-prefix"
            && ((route.intent or { }).accessNode or null) == targetNode)
          staticReturnRoutes;
    in
      bgpAccess.routingMode == "bgp"
      && builtins.elem "fd42:dead:feed:70::1/64" bgpAccess.bgp.networks.ipv6
      && hasPrefixBySource "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile" bgpRuntimePrefixes
      && hasPrefixBySource "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile" (bgpRa.routedPrefixes or [ ])
      && hasRuntimePrefixReturnRoute "/run/secrets/access-node-ipv6-prefix-espbranch-site-b-b-router-access-hostile" bgpCoreUpstreamRoutes
      && !(bgpAccess ? externalValidation)
      && !(bgpRa ? externalValidation)
      && staticSite.routing.mode == "static"
      && staticSite.ipv6.pd.delegatedPrefixLength == 48
      && staticSite.ipv6.pd.perTenantPrefixLength == 64
      && staticSite.ipv6.pd.uplink == "wan"
      && staticSite.ipv6.tenants.client-a.mode == "dhcpv6"
      && staticSite.ipv6.tenants.client-b.mode == "slaac"
      && staticSite.ipv6.tenants.mgmt.mode == "static"
      && staticAccess.routingMode == "static"
      && hasPrefixBySource "/run/s88-ipv6-pd/wan.prefix" (staticRa.routedPrefixes or [ ])
      && hasStaticReturnRoute "s-router-access-client-b" "/run/s88-ipv6-pd/wan.prefix"
      && staticP2pGuaAddrs == [ ]
      && !(staticAccess ? bgp)
  '
)"

if [[ "${check_result}" != "true" ]]; then
  echo "FAIL runtime-routed-prefixes-no-validation-shortcut: CPM did not preserve both BGP and static modeled runtime IPv6 prefix contracts" >&2
  exit 1
fi

echo "PASS runtime-routed-prefixes-no-validation-shortcut"
