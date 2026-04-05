#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"
golden_input_file="${repo_root}/fixtures/passing/golden-no-guessing-base/input.nix"

status=0

run_case() {
  local name="$1"
  local expected="$2"
  local input_nix="$3"
  local inventory_nix="$4"

  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  printf '%s\n' "$input_nix" > "${tmp_dir}/input.nix"
  printf '%s\n' "$inventory_nix" > "${tmp_dir}/inventory.nix"

  local stderr_file
  stderr_file="$(mktemp)"

  local expr
  expr="let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${tmp_dir}/input.nix;
    inventory = import ${tmp_dir}/inventory.nix;
  in
    builder { inherit input inventory; }"

  if nix eval --impure --json --expr "${expr}" >/dev/null 2>"${stderr_file}"; then
    echo "FAIL ${name}: evaluation unexpectedly succeeded"
    status=1
  else
    if grep -Fq "${expected}" "${stderr_file}"; then
      echo "PASS ${name}"
    else
      echo "FAIL ${name}: missing expected error"
      echo "expected: ${expected}"
      echo "stderr:"
      cat "${stderr_file}"
      status=1
    fi
  fi

  rm -f "${stderr_file}"
  rm -rf "${tmp_dir}"
  trap - RETURN
}

mutate_once_with_nix() {
  local source_file="$1"
  local op="$2"
  local old_file="$3"
  local new_file="${4:-}"

  local expr
  case "$op" in
    replace)
      expr="
        let
          text = builtins.readFile ${source_file};
          old = builtins.readFile ${old_file};
          new = builtins.readFile ${new_file};
          out = builtins.replaceStrings [ old ] [ new ] text;
        in
        if out == text then
          throw \"mutation failed: replace pattern not found\"
        else
          out
      "
      ;;
    delete)
      expr="
        let
          text = builtins.readFile ${source_file};
          old = builtins.readFile ${old_file};
          out = builtins.replaceStrings [ old ] [ \"\" ] text;
        in
        if out == text then
          throw \"mutation failed: delete pattern not found\"
        else
          out
      "
      ;;
    *)
      echo "unknown mutation op: ${op}" >&2
      return 1
      ;;
  esac

  nix eval --impure --raw --expr "${expr}"
}

mutate_input() {
  local work_dir
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' RETURN

  local current_file="${work_dir}/current.nix"
  cp "${golden_input_file}" "${current_file}"

  while (($# > 0)); do
    local op="$1"
    shift

    case "$op" in
      replace)
        local old="$1"
        local new="$2"
        shift 2

        local old_file="${work_dir}/old.txt"
        local new_file="${work_dir}/new.txt"
        local next_file="${work_dir}/next.nix"

        printf '%s' "${old}" > "${old_file}"
        printf '%s' "${new}" > "${new_file}"
        mutate_once_with_nix "${current_file}" replace "${old_file}" "${new_file}" > "${next_file}"
        mv "${next_file}" "${current_file}"
        ;;
      delete)
        local old="$1"
        shift

        local old_file="${work_dir}/old.txt"
        local next_file="${work_dir}/next.nix"

        printf '%s' "${old}" > "${old_file}"
        mutate_once_with_nix "${current_file}" delete "${old_file}" > "${next_file}"
        mv "${next_file}" "${current_file}"
        ;;
      *)
        echo "unknown mutation op: ${op}" >&2
        return 1
        ;;
    esac
  done

  cat "${current_file}"
  trap - RETURN
  rm -rf "${work_dir}"
}

run_case_from_golden() {
  local name="$1"
  local expected="$2"
  shift 2
  run_case "$name" "$expected" "$(mutate_input "$@")" '{}'
}

run_case \
  "missing-explicit-runtime-target-realization" \
  "inventory.nix must explicitly realize every control_plane_model runtime target" \
  "$(cat "${golden_input_file}")" \
  '{}'

run_case_from_golden \
  "pair-based-transit-ordering" \
  "transit.ordering must contain only stable adjacency IDs" \
  replace \
  '            ordering = [
              "adj::acme.ams::core-upstream"
              "adj::acme.ams::upstream-policy"
              "adj::acme.ams::policy-access"
            ];' \
  '            ordering = [
              [ "core-1" "upstream-1" ]
              [ "upstream-1" "policy-1" ]
              [ "policy-1" "access-1" ]
            ];'

run_case_from_golden \
  "missing-transit-adjacency-id" \
  "transit.adjacencies[0].id is required" \
  delete \
  '                id = "adj::acme.ams::core-upstream";
'

run_case_from_golden \
  "missing-link-id" \
  "links.link-core-upstream.id is required" \
  delete \
  '              id = "adj::acme.ams::core-upstream";
'

run_case_from_golden \
  "adjacency-link-id-mismatch" \
  "does not match links.link-core-upstream.id" \
  replace \
  '                id = "adj::acme.ams::core-upstream";' \
  '                id = "adj::acme.ams::wrong-core-upstream";'

run_case_from_golden \
  "interface-name-must-be-explicit" \
  "forwardingModel.enterprise.acme.site.ams.nodes.access-1.interfaces.tenant0.interface is required" \
  delete \
  '                  interface = "tenant-a";
'

run_case_from_golden \
  "tenant-interface-missing-tenant" \
  "tenant interface requires explicit tenant" \
  delete \
  '                  tenant = "tenant-a";
'

run_case_from_golden \
  "tenant-interface-requires-explicit-site-attachment" \
  "tenant interface requires explicit site.attachments entry" \
  replace \
  '          attachments = [
            {
              kind = "tenant";
              name = "tenant-a";
              unit = "access-1";
            }
          ];' \
  '          attachments = [ ];'

run_case_from_golden \
  "access-node-missing-explicit-tenant-identity" \
  "access node requires at least one tenant interface with explicit tenant" \
  replace \
  '                tenant0 = {
                  interface = "tenant-a";
                  kind = "tenant";
                  tenant = "tenant-a";
                  addr4 = "10.20.0.1/24";
                  addr6 = "fd00:20::1/64";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };' \
  '                tenant0 = {
                  interface = "tenant-a";
                  kind = "lan";
                  addr4 = "10.20.0.1/24";
                  addr6 = "fd00:20::1/64";
                  routes = {
                    ipv4 = [ ];
                    ipv6 = [ ];
                  };
                };'

run_case_from_golden \
  "overlay-interface-missing-explicit-overlay" \
  "overlay interface requires explicit overlay" \
  delete \
  '                  overlay = "nebula-east-west";
'

run_case_from_golden \
  "wan-interface-missing-explicit-upstream" \
  "wan interface requires explicit upstream" \
  delete \
  '                  upstream = "wan";
'

run_case_from_golden \
  "wan-interface-missing-explicit-link" \
  "wan interface requires explicit link" \
  delete \
  '                  link = "wan-core";
'

run_case_from_golden \
  "bgp-mode-without-explicit-sessions" \
  "bgp mode requires explicit site.bgp.sessions" \
  replace \
  '          communicationContract = {' \
  '          bgp = {
            mode = "bgp";
          };

          communicationContract = {'

run_case_from_golden \
  "missing-canonical-interface-tags" \
  "site.policy.interfaceTags is required" \
  delete \
  '          policy = {
            interfaceTags = {
              tenant0 = "tenant-a";
              uplink0 = "wan";
            };
          };
'

run_case_from_golden \
  "legacy-contract-interface-tags-not-allowed" \
  "communicationContract.interfaceTags is not allowed; use site.policy.interfaceTags" \
  replace \
  '          communicationContract = {
            allowedRelations = [' \
  '          communicationContract = {
            interfaceTags = {
              legacy-tenant0 = "tenant-a";
              legacy-uplink0 = "wan";
            };
            allowedRelations = ['

run_case_from_golden \
  "policy-contract-references-unmapped-tenant-tag" \
  "communicationContract references tag 'tenant-a' with no explicit site.policy.interfaceTags mapping" \
  replace \
  '              tenant0 = "tenant-a";' \
  '              tenant0 = "tenant-z";'

run_case_from_golden \
  "external-reference-without-explicit-policy-mapping" \
  "communicationContract references tag 'internet' with no explicit site.policy.interfaceTags mapping" \
  replace \
  '              {
                from = {
                  kind = "tenant";
                  name = "tenant-a";
                };
                to = {
                  kind = "external";
                  name = "wan";
                };
                action = "allow";
              }' \
  '              {
                from = {
                  kind = "tenant";
                  name = "tenant-a";
                };
                to = {
                  kind = "external";
                  name = "internet";
                };
                action = "allow";
              }'

run_case \
  "realized-link-interface-requires-explicit-matching-link" \
  "requires explicit port realization for backing link 'adj::acme.ams::policy-access'" \
  "$(cat "${golden_input_file}")" \
  "$(cat <<'EOF'
{
  deployment = {
    hosts = {
      hypervisor-a = {
        uplinks = { };
        bridgeNetworks = {
          br-transit = { };
        };
      };
    };
  };

  realization = {
    nodes = {
      access-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "acme";
          site = "ams";
          name = "access-1";
        };
        ports = {
          p2p0 = {
            link = "unknown-link";
            interface = {
              name = "ens3";
            };
            attach = {
              kind = "bridge";
              bridge = "br-transit";
            };
          };
        };
      };
    };
  };
}
EOF
)"

run_case \
  "realized-wan-interface-requires-explicit-upstream-addressing" \
  "requires explicit upstream addressing in inventory.deployment.hosts.hypervisor-a.uplinks.uplink0.ipv4 and/or ipv6" \
  "$(cat "${golden_input_file}")" \
  "$(cat <<'EOF'
{
  deployment = {
    hosts = {
      hypervisor-a = {
        uplinks = {
          uplink0 = {
            parent = "eno1";
            bridge = "br-wan";
          };
        };
      };
    };
  };

  realization = {
    nodes = {
      core-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "acme";
          site = "ams";
          name = "core-1";
        };
        ports = {
          p2p-upstream = {
            link = "link-core-upstream";
            attach = {
              kind = "bridge";
              bridge = "br-wan";
            };
            interface = {
              name = "ens3";
            };
          };

          uplink0 = {
            external = true;
            uplink = "wan";
            attach = {
              kind = "bridge";
              bridge = "br-wan";
            };
            interface = {
              name = "ens4";
            };
          };
        };
      };
    };
  };
}
EOF
)"

exit "${status}"
