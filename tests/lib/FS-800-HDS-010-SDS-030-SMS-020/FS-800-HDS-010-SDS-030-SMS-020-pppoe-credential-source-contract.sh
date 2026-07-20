#!/usr/bin/env bash
# GAMP-ID: FS-800-HDS-010-SDS-030-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"
intent_path="${hat_dir}/intent.nix"
inventory_path="${hat_dir}/inventory-nixos.nix"

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory}" \
    "${output}" >/dev/null
}

expect_failure() {
  local name="$1"
  local inventory="$2"
  local expected="$3"
  local stderr_path="${tmp_dir}/${name}.stderr"

  if build_cpm "${inventory}" "${tmp_dir}/${name}.json" 2>"${stderr_path}"; then
    echo "FAIL pppoe-credential-source-contract: ${name} unexpectedly evaluated" >&2
    exit 1
  fi

  if ! grep -Fq "${expected}" "${stderr_path}"; then
    echo "FAIL pppoe-credential-source-contract: ${name} missing diagnostic" >&2
    echo "expected substring: ${expected}" >&2
    cat "${stderr_path}" >&2
    exit 1
  fi
}

build_cpm "${inventory_path}" "${tmp_dir}/positive.json"

jq -e '
  def pppoeTargets:
    [
      .control_plane_model.data.esp0xdeadbeef
      | to_entries[].value.runtimeTargets
      | to_entries[]
      | select(.value.services.pppoe? != null)
      | .value.services.pppoe
    ];
  def fileCredentialOk($credentials):
    $credentials.labOnly == true
    and ($credentials | has("username") | not)
    and ($credentials | has("password") | not)
    and $credentials.usernameFile == "/run/secrets/hat-pppoe-username"
    and $credentials.passwordFile == "/run/secrets/hat-pppoe-password";
  pppoeTargets as $targets
  | ($targets | length) > 0
    and all($targets[];
      if .client? then fileCredentialOk(.client.credentials)
      elif .server? then fileCredentialOk(.server.credentials)
      else false
      end)
' "${tmp_dir}/positive.json" >/dev/null

cat >"${tmp_dir}/mixed-credentials.nix" <<EOF
let
  base = import ${inventory_path};
  nodes = base.realization.nodes;
  nodeName = "esp0xdeadbeef-site-a-nixos-core-testnet-host-isp";
  node = nodes.\${nodeName};
  client = node.services.pppoe.client;
in
base // {
  realization = base.realization // {
    nodes = nodes // {
      \${nodeName} = node // {
        services = node.services // {
          pppoe = node.services.pppoe // {
            client = client // {
              credentials = client.credentials // {
                username = "hat-pppoe";
              };
            };
          };
        };
      };
    };
  };
}
EOF

cat >"${tmp_dir}/missing-credentials.nix" <<EOF
let
  base = import ${inventory_path};
  nodes = base.realization.nodes;
  nodeName = "esp0xdeadbeef-site-a-nixos-core-testnet-host-isp";
  node = nodes.\${nodeName};
  client = node.services.pppoe.client;
in
base // {
  realization = base.realization // {
    nodes = nodes // {
      \${nodeName} = node // {
        services = node.services // {
          pppoe = node.services.pppoe // {
            client = client // {
              credentials = {
                labOnly = true;
              };
            };
          };
        };
      };
    };
  };
}
EOF

expect_failure \
  "mixed-credentials" \
  "${tmp_dir}/mixed-credentials.nix" \
  "credentials: must use either inline username/password or usernameFile/passwordFile, not both"

expect_failure \
  "missing-credentials" \
  "${tmp_dir}/missing-credentials.nix" \
  "credentials: must define username/password or usernameFile/passwordFile"

echo "PASS pppoe-credential-source-contract"
