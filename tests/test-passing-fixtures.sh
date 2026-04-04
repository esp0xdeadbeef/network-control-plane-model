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
    minimal-forwarding-model-v6)
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

run_warning_case() {
  local name="$1"
  local input_nix="$2"
  local inventory_nix="$3"

  log "Running ${name}"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  printf '%s\n' "$input_nix" > "${tmp_dir}/input.nix"
  printf '%s\n' "$inventory_nix" > "${tmp_dir}/inventory.nix"

  local stderr_file
  stderr_file="${tmp_dir}/stderr.log"

  local expr
  expr="let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${tmp_dir}/input.nix;
    inventory = import ${tmp_dir}/inventory.nix;
  in
    builder { inherit input inventory; }"

  nix eval --show-trace --impure --json --expr "${expr}" > "${tmp_dir}/out.json" 2>"${stderr_file}" \
    || {
      echo "--- INPUT ---"
      cat "${tmp_dir}/input.nix"
      echo "--- INVENTORY ---"
      cat "${tmp_dir}/inventory.nix"
      echo "--- STDERR ---"
      cat "${stderr_file}"
      fail "FAIL ${name}: evaluation failed"
    }

  grep -Fq "migration warning:" "${stderr_file}" \
    || fail "FAIL ${name}: expected migration warnings"

  [[ "$(grep -Fc "meta.solver is solver-era input and is ignored" "${stderr_file}")" -eq 1 ]] \
    || fail "FAIL ${name}: expected exactly one meta.solver warning"

  [[ "$(grep -Fc "site.transport is a compatibility input and is not treated as canonical forwarding-model authority by CPM" "${stderr_file}")" -eq 1 ]] \
    || fail "FAIL ${name}: expected exactly one site.transport warning"

  [[ "$(grep -Fc "site.policy is a migration-era compatibility input and is not canonical forwarding-model authority for CPM topology/runtime semantics" "${stderr_file}")" -eq 1 ]] \
    || fail "FAIL ${name}: expected exactly one site.policy warning"

  [[ "$(grep -Fc "runtime forwarding semantics are not yet fully explicit for all node roles" "${stderr_file}")" -eq 1 ]] \
    || fail "FAIL ${name}: expected exactly one role-based semantics warning"

  [[ "$(grep -Fc "tenant interfaces still accept the legacy link field during migration" "${stderr_file}")" -eq 1 ]] \
    || fail "FAIL ${name}: expected exactly one tenant legacy-link warning"

  print_warnings_if_any "${name}" "${stderr_file}"
  echo "PASS ${name}"

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
      schemaVersion = 6;
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
          nodes = {};
        };
      };
    };
  };
}'

warning_input='{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 6;
    };

    solver = {
      compatibility = true;
    };
  };

  enterprise = {
    acme = {
      site = {
        ams = {
          siteId = "ams";
          siteName = "acme.ams";

          attachments = [
            {
              kind = "tenant";
              name = "tenant-a";
              unit = "access-1";
            }
            {
              kind = "tenant";
              name = "tenant-b";
              unit = "access-1";
            }
          ];

          policyNodeName = "policy-1";
          upstreamSelectorNodeName = "policy-1";
          coreNodeNames = [];
          uplinkCoreNames = [];
          uplinkNames = [];

          domains = {
            tenants = [
              {
                name = "tenant-a";
                ipv4 = "10.20.0.0/24";
                ipv6 = "fd00:20::/64";
              }
              {
                name = "tenant-b";
                ipv4 = "10.21.0.0/24";
                ipv6 = "fd00:21::/64";
              }
            ];
            externals = [];
          };

          tenantPrefixOwners = {
            "4|10.20.0.0/24" = {
              family = 4;
              dst = "10.20.0.0/24";
              netName = "tenant-a";
              owner = "access-1";
            };
            "4|10.21.0.0/24" = {
              family = 4;
              dst = "10.21.0.0/24";
              netName = "tenant-b";
              owner = "access-1";
            };
          };

          links = {};
          transit = {
            adjacencies = [];
            ordering = [];
          };

          transport = {
            overlays = {};
          };

          policy = {};

          communicationContract = {
            interfaceTags = {};
            allowedRelations = [];
          };

          nodes = {
            access-1 = {
              role = "access";
              loopback = {
                ipv4 = "10.255.0.2/32";
                ipv6 = "fd00:ff:1::2/128";
              };
              interfaces = {
                tenant0 = {
                  interface = "tenant-a";
                  kind = "tenant";
                  tenant = "tenant-a";
                  link = "legacy-tenant-link-a";
                  addr4 = "10.20.0.1/24";
                  addr6 = "fd00:20::1/64";
                  routes = {
                    ipv4 = [];
                    ipv6 = [];
                  };
                };
                tenant1 = {
                  interface = "tenant-b";
                  kind = "tenant";
                  tenant = "tenant-b";
                  link = "legacy-tenant-link-b";
                  addr4 = "10.21.0.1/24";
                  addr6 = "fd00:21::1/64";
                  routes = {
                    ipv4 = [];
                    ipv6 = [];
                  };
                };
              };
            };

            policy-1 = {
              role = "policy";
              loopback = {
                ipv4 = "10.255.0.1/32";
                ipv6 = "fd00:ff:1::1/128";
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

run_case "minimal-forwarding-model-v6" "$minimal_input" "{}" "minimal-forwarding-model-v6"
run_case "minimal-forwarding-model-v6-pppoe" "$pppoe_input" "{}" "minimal-forwarding-model-v6-pppoe"
run_case "hosted-runtime-targets" "$hosted_input" "$hosted_inventory" "hosted-runtime-targets"
run_warning_case "migration-warnings-visible" "$warning_input" "{}"

run_external_examples

exit 0
