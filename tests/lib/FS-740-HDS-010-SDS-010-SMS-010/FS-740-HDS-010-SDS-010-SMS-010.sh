#!/usr/bin/env bash
# GAMP-ID: FS-740-HDS-010-SDS-010-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq
require_cmd nix

hat_dir="$(pinned_hat_dir)"
tmp_dir="$(mktemp -d)"
output_json="${tmp_dir}/control-plane.json"
trap 'rm -rf "${tmp_dir}"' EXIT

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${hat_dir}/intent.nix" \
  "${hat_dir}/inventory-clab.nix" \
  "${output_json}" >/dev/null

jq -e '
  def source_key:
    [ (.sourcePrefixes // [])[]? | { family: (.family // null), prefix: (.prefix // "") } ]
    | sort_by(.family // 0, .prefix);

  .control_plane_model.data.esp0xdeadbeef["site-b"].runtimeTargets
  | to_entries[]
  | select(.value.role == "policy")
  | .value.forwardingIntent.rules as $rules
  | [ $rules[]
      | select(.relationId == "allow-hat-site-dns-service-to-client-uplinks")
      | {
          relationId,
          action,
          trafficType,
          fromInterface,
          toInterface,
          sourcePrefixes: (.sourcePrefixes // []),
          matches
        }
    ] as $serviceAllows
  | [ $rules[]
      | select(.relationId == "deny-client-dns-to-uplinks")
      | {
          relationId,
          action,
          trafficType,
          fromInterface,
          toInterface,
          sourcePrefixes: (.sourcePrefixes // []),
          matches
        }
    ] as $clientDenies
  | {
      serviceAllows: $serviceAllows,
      clientDenies: $clientDenies,
      ok:
        ($serviceAllows | length == 2)
        and ($clientDenies | length == 2)
        and all($serviceAllows[];
          .action == "accept"
          and .trafficType == "dns"
          and any((.sourcePrefixes // [])[]?; .family == 4 and .prefix == "10.50.20.1")
          and any((.sourcePrefixes // [])[]?; .family == 6 and .prefix == "fd42:dead:feed:20::1")
        )
        and all($clientDenies[];
          .action == "deny"
          and .trafficType == "dns"
          and ((.sourcePrefixes // []) == [])
        )
        and all($serviceAllows[];
          . as $allow
          | all($clientDenies[];
            . as $deny
            |
            if
              $allow.fromInterface == $deny.fromInterface
              and $allow.toInterface == $deny.toInterface
              and $allow.trafficType == $deny.trafficType
              and (($allow.matches // []) == ($deny.matches // []))
            then
              ($allow | source_key) != ($deny | source_key)
            else
              true
            end
          )
        )
    }
  | select(.ok == true)
' "${output_json}" >/dev/null || {
  echo "FAIL hat-clab-dns-relation-source-scope: service-origin DNS allow and tenant-origin DNS deny collapsed to an indistinguishable policy-router tuple" >&2
  jq '
    .control_plane_model.data.esp0xdeadbeef["site-b"].runtimeTargets
    | to_entries[]
    | select(.value.role == "policy")
    | {
        target: .key,
        dnsRelationRules: [
          .value.forwardingIntent.rules[]
          | select(.relationId == "allow-hat-site-dns-service-to-client-uplinks" or .relationId == "deny-client-dns-to-uplinks")
          | {
              relationId,
              action,
              trafficType,
              fromInterface,
              toInterface,
              sourcePrefixes: (.sourcePrefixes // []),
              matches
            }
        ]
      }
  ' "${output_json}" >&2
  exit 1
}

echo "PASS hat-clab-dns-relation-source-scope"
