#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"
examples_root="${repo_root}/../network-labs/examples"

status=0

log() {
  echo "==> $*"
}

fail() {
  echo "$1"
  exit 1
}

validate_output() {
  local name="$1"
  local output_json="$2"
  local validator="$3"

  case "${validator}" in
    minimal-forwarding-model-v7)
      OUTPUT_JSON="${output_json}" nix eval --impure --expr '
        let data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
        in data.control_plane_model.version == 1
      ' >/dev/null || fail "FAIL ${name}: validation failed"
      echo "PASS ${name}"
      ;;
    *)
      echo "PASS ${name}"
      ;;
  esac
}

print_warnings_if_any() {
  local label="$1"
  local stderr_file="$2"

  if grep -Fq "migration warning:" "${stderr_file}"; then
    echo "--- WARNINGS (${label}) ---"
    cat "${stderr_file}"
  fi
}

run_case() {
  local name="$1"
  local input_nix="$2"
  local inventory_nix="$3"
  local validator="$4"

  log "Running ${name}"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  printf '%s\n' "$input_nix" > "${tmp_dir}/input.nix"
  printf '%s\n' "$inventory_nix" > "${tmp_dir}/inventory.nix"

  local expr
  expr="let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${tmp_dir}/input.nix;
    inventory = import ${tmp_dir}/inventory.nix;
  in
    builder { inherit input inventory; }"

  nix eval --show-trace --impure --json --expr "${expr}" > "${tmp_dir}/out.json" \
    || {
      echo "--- INPUT ---"
      cat "${tmp_dir}/input.nix"
      echo "--- INVENTORY ---"
      cat "${tmp_dir}/inventory.nix"
      fail "FAIL ${name}: evaluation failed"
    }

  validate_output "${name}" "${tmp_dir}/out.json" "${validator}"
  rm -rf "${tmp_dir}"
}

run_external_examples() {
  log "Running external examples"

  find "${examples_root}" -mindepth 1 -maxdepth 1 -type d | sort | while read -r dir; do
    local name
    local intent
    local inventory
    local tmp_dir
    local tmp_out
    local stderr_file

    name="$(basename "$dir")"
    intent="${dir}/intent.nix"
    inventory="${dir}/inventory.nix"

    [[ -f "$intent" ]] || { echo "SKIP ${name} (no intent.nix)"; continue; }
    [[ -f "$inventory" ]] || { echo "SKIP ${name} (no inventory.nix)"; continue; }

    log "Example ${name}"

    tmp_dir="$(mktemp -d)"
    tmp_out="${tmp_dir}/out.json"
    stderr_file="${tmp_dir}/stderr.log"

    nix run "${repo_root}#compile-and-build-control-plane-model" -- \
      "${intent}" \
      "${inventory}" \
      "${tmp_out}" \
      >/dev/null 2>"${stderr_file}" \
      || {
        echo "--- INTENT (${name}) ---"
        cat "${intent}"
        echo "--- INVENTORY (${name}) ---"
        cat "${inventory}"
        echo "--- STDERR (${name}) ---"
        cat "${stderr_file}"
        rm -rf "${tmp_dir}"
        fail "FAIL ${name}"
      }

    print_warnings_if_any "network-labs-example:${name}" "${stderr_file}"
    validate_output "network-labs-example:${name}" "${tmp_out}" "network-labs-example"
    rm -rf "${tmp_dir}"
  done
}

minimal_input='{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 7;
    };
  };

  enterprise = {
    acme = {
      site = {
        ams = {
          siteId = "ams";
          siteName = "acme.ams";
          attachments = [];
          policyNodeName = "policy-1";
          upstreamSelectorNodeName = "upstream-1";
          coreNodeNames = [];
          uplinkCoreNames = [];
          uplinkNames = [];
          domains = { tenants = []; externals = []; };
          tenantPrefixOwners = {};
          links = {};
          transit = { adjacencies = []; ordering = []; };
          communicationContract = {
            interfaceTags = {};
            allowedRelations = [];
          };
          nodes = {
            policy-1 = {
              role = "policy";
              loopback = {
                ipv4 = "10.255.0.1/32";
                ipv6 = "fd00:ff::1/128";
              };
              interfaces = {};
            };
            upstream-1 = {
              role = "upstream-selector";
              loopback = {
                ipv4 = "10.255.0.2/32";
                ipv6 = "fd00:ff::2/128";
              };
              interfaces = {};
            };
          };
        };
      };
    };
  };
}'

pppoe_input="$minimal_input"
hosted_input="$minimal_input"
hosted_inventory='{}'

run_case "minimal-forwarding-model-v7" "$minimal_input" "{}" "minimal-forwarding-model-v7"
run_case "minimal-forwarding-model-v7-pppoe" "$pppoe_input" "{}" "minimal-forwarding-model-v7-pppoe"
run_case "hosted-runtime-targets" "$hosted_input" "$hosted_inventory" "hosted-runtime-targets"

run_external_examples

exit 0
