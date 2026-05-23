#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd gron
require_cmd jq
require_cmd nix
require_cmd rg

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

labs_path="$(flake_input_path network-labs)"
output_json="$(mktemp)"
gron_txt="$(mktemp)"
trap 'rm -f "${output_json}" "${gron_txt}"' EXIT

nix run "${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/labs/lab-s-sigma/s-router-test-three-site/intent.nix" \
  "${labs_path}/labs/lab-s-sigma/s-router-test-three-site/inventory.nix" \
  "${output_json}" >/dev/null

gron "${output_json}" >"${gron_txt}"

require_gron() {
  local pattern="$1"
  if ! rg -q --fixed-strings "${pattern}" "${gron_txt}"; then
    echo "FAIL runtime-origin-loopback-egress: missing gron line: ${pattern}" >&2
    exit 1
  fi
}

require_gron_regex() {
  local pattern="$1"
  if ! rg -q "${pattern}" "${gron_txt}"; then
    echo "FAIL runtime-origin-loopback-egress: missing gron regex: ${pattern}" >&2
    exit 1
  fi
}

require_gron 'json.control_plane_model.data.esp.nixos.runtimeTargets["esp-nixos-router-core-nebula"].runtimeOriginEgress.enabled = true;'
require_gron 'json.control_plane_model.data.esp.nixos.runtimeTargets["esp-nixos-router-core-nebula"].runtimeOriginEgress.sourcePrefixes[0].prefix = "10.19.0.8/32";'
require_gron 'json.control_plane_model.data.esp.nixos.runtimeTargets["esp-nixos-router-core-nebula"].runtimeOriginEgress.sourcePrefixes[1].prefix = "fd42:dead:beef:1900:0:0:0:8/128";'
require_gron_regex 'json\.control_plane_model\.data\.esp\.nixos\.runtimeTargets\["esp-nixos-router-core-nebula"\]\.effectiveRuntimeRealization\.interfaces\["p2p-nixos-router-access-client-nixos-router-core-nebula"\]\.routes\.ipv4\[[0-9]+\]\.preferredSource = "10\.19\.0\.8";'
require_gron_regex 'json\.control_plane_model\.data\.esp\.nixos\.runtimeTargets\["esp-nixos-router-core-nebula"\]\.effectiveRuntimeRealization\.interfaces\["p2p-nixos-router-access-client-nixos-router-core-nebula"\]\.routes\.ipv6\[[0-9]+\]\.preferredSource = "fd42:dead:beef:1900:0:0:0:8";'

env \
  REPO_ROOT="${repo_root}" \
  OUTPUT_JSON="${output_json}" \
  nix eval \
    --extra-experimental-features 'nix-command flakes' \
    --impure --expr '
      let
        cpm = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
        site = cpm.control_plane_model.data.esp.nixos;
        core = site.runtimeTargets."esp-nixos-router-core-nebula";
        upstream = site.runtimeTargets."esp-nixos-router-upstream";
        runtimeOrigin = core.runtimeOriginEgress or { };
        sourcePrefixes = runtimeOrigin.sourcePrefixes or [ ];
        hasPrefix = prefix:
          builtins.any (entry: (entry.prefix or null) == prefix) sourcePrefixes;
        upstreamRules = upstream.forwardingIntent.rules or [ ];
        allRuntimeRules =
          builtins.filter
            (rule:
              (rule.intent.kind or null) == "runtime-origin-egress")
            upstreamRules;
        runtimeRules = builtins.filter (rule: (rule.fromInterface or null) == "core-nebula") allRuntimeRules;
        ruleHasPrefix = prefix:
          builtins.any
            (rule:
              builtins.any (entry: (entry.prefix or null) == prefix) (rule.sourcePrefixes or [ ]))
            runtimeRules;
        ruleHasP2pSource =
          builtins.any
            (rule:
              builtins.any (entry: (entry.prefix or null) == "10.10.0.16/31") (rule.sourcePrefixes or [ ]))
            runtimeRules;
        underlayIface = core.effectiveRuntimeRealization.interfaces."p2p-nixos-router-access-client-nixos-router-core-nebula";
        overlayIface = core.effectiveRuntimeRealization.interfaces."p2p-nixos-router-core-nebula-nixos-router-upstream";
        underlayDefaultRoutes = builtins.filter (route: (route.dst or null) == "0.0.0.0/0") (underlayIface.routes.ipv4 or [ ]);
        overlayDefaultRoutes = builtins.filter (route: (route.dst or null) == "0.0.0.0/0") (overlayIface.routes.ipv4 or [ ]);
        underlayDefaultHasPreferredSource =
          builtins.any (route: (route.preferredSource or null) == "10.19.0.8") underlayDefaultRoutes;
      in
        (runtimeOrigin.enabled or false)
        && hasPrefix "10.19.0.8/32"
        && hasPrefix "fd42:dead:beef:1900:0:0:0:8/128"
        && builtins.length sourcePrefixes == 2
        && builtins.length allRuntimeRules == 1
        && builtins.length runtimeRules == 1
        && ((builtins.head runtimeRules).toInterface or null) == "core-isp-a"
        && ruleHasPrefix "10.19.0.8/32"
        && ruleHasPrefix "fd42:dead:beef:1900:0:0:0:8/128"
        && !ruleHasP2pSource
        && underlayDefaultHasPreferredSource
        && builtins.length overlayDefaultRoutes == 0
    ' >/dev/null

echo "PASS runtime-origin-loopback-egress"
