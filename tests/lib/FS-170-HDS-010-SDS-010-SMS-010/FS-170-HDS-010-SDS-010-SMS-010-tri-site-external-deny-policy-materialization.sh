#!/usr/bin/env bash
# GAMP-ID: FS-170-HDS-010-SDS-010-SMS-010
# GAMP-ID: SMT-CPM-EXPLICIT-DENY-MATERIALIZATION-001
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

archive_json="${tmp_dir}/archive.json"
output_json="${tmp_dir}/output.json"

nix flake archive --json "path:${repo_root}" >"${archive_json}"

labs_path="$(
  ARCHIVE_JSON="${archive_json}" nix eval --impure --raw --expr '
    let
      archived = builtins.fromJSON (builtins.readFile (builtins.getEnv "ARCHIVE_JSON"));
      labs = archived.inputs."network-labs" or null;
      labsPath = if labs == null then null else labs.path or null;
    in
      if labsPath == null then throw "tests: missing archived network-labs input path" else labsPath
  '
)"

nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
  "${labs_path}/examples/tri-site-s-router-overlay-egress/intent.nix" \
  "${labs_path}/examples/tri-site-s-router-overlay-egress/inventory.nix" \
  "${output_json}" >/dev/null

jq -e '
  def rules($site; $target; $relation):
    [
      .control_plane_model.data.esp[$site].runtimeTargets[$target].forwardingIntent.rules[]?
      | select((.relationId // null) == $relation)
    ];

  def all_deny($rules; $priority):
    ($rules | length) > 0
    and all($rules[];
      (.action // null) == "deny"
      and (.trafficType // null) == "any"
      and (.priority // null) == $priority
      and (.from.kind // null) == "tenant-set"
      and ((.from.members // []) | index("hostile") != null));

  def home_ok:
    rules("home"; "esp-home-example-router-policy"; "deny-hostile-to-local-uplinks") as $rules
    | all_deny($rules; 26)
      and all($rules[];
        (.fromInterface // null) == "down-hostile"
        and (.to.kind // null) == "external"
        and ((.to.uplinks // []) | index("isp-a") != null)
        and ((.to.uplinks // []) | index("isp-b") != null)
        and ((.toInterface // "") | startswith("up-"))
        and (.toInterface // "") != "up-hostile-ew")
      and any($rules[]; (.toInterface // "") | endswith("-a"))
      and any($rules[]; (.toInterface // "") | endswith("-b"));

  def lab_ok:
    rules("lab"; "esp-lab-example-router-policy"; "deny-hostile-to-local-wan") as $rules
    | all_deny($rules; 101)
      and all($rules[];
        (.fromInterface // null) == "down-hostile"
        and (.to.kind // null) == "external"
        and (.to.name // null) == "wan"
        and ((.toInterface // "") | startswith("up-"))
        and (.toInterface // "") != "up-hostile-ew")
      and any($rules[]; (.toInterface // "") == "up-admin" or (.toInterface // "") == "up-client" or (.toInterface // "") == "up-dmz" or (.toInterface // "") == "up-stream");

  home_ok and lab_ok
' "${output_json}" >/dev/null || {
  echo "FAIL tri-site-external-deny-policy-materialization: CPM must emit explicit deny policy rules for hostile-to-local-uplink/WAN relations" >&2
  jq '
    {
      home:
        [.control_plane_model.data.esp.home.runtimeTargets."esp-home-example-router-policy".forwardingIntent.rules[]?
        | select((.relationId // null) == "deny-hostile-to-local-uplinks")],
      lab:
        [.control_plane_model.data.esp.lab.runtimeTargets."esp-lab-example-router-policy".forwardingIntent.rules[]?
        | select((.relationId // null) == "deny-hostile-to-local-wan")]
    }
  ' "${output_json}" >&2
  exit 1
}

echo "PASS tri-site-external-deny-policy-materialization"
