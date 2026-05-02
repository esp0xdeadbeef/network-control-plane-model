#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

input_fixture="${repo_root}/fixtures/passing/default-egress-reachability/input.nix"
inventory_fixture="${repo_root}/fixtures/passing/default-egress-reachability/inventory.nix"

nix eval \
  --impure \
  --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      builder = flake.lib.${system}.build;
      baseInput = import ${input_fixture};
      inventory = import ${inventory_fixture};
      baseSite = baseInput.enterprise.acme.site.ams;
      lane = \"access::access-1::uplink::wan\";
      input =
        baseInput
        // {
          enterprise =
            baseInput.enterprise
            // {
              acme =
                baseInput.enterprise.acme
                // {
                  site =
                    baseInput.enterprise.acme.site
                    // {
                      ams =
                        baseSite
                        // {
                          links =
                            baseSite.links
                            // {
                              link-upstream-policy =
                                baseSite.links.link-upstream-policy
                                // {
                                  inherit lane;
                                };
                            };
                        };
                    };
                };
            };
        };
      out = builder { inherit input inventory; };
      iface =
        out.control_plane_model.data.acme.ams.runtimeTargets.policy-runtime
          .effectiveRuntimeRealization.interfaces.p2p-upstream;
    in
      iface.backingRef.lane == lane
  " | grep -qx true

echo "PASS link-lane-preservation"
