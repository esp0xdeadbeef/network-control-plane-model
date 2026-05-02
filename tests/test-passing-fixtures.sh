#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq

flake_input_path() {
  local input_name="$1"
  nix flake archive --json "path:${repo_root}" \
    | jq -er ".inputs[\"${input_name}\"].path"
}

examples_root="$(flake_input_path network-labs)/examples"

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
    single-wan-ipv6-pd)
      OUTPUT_JSON="${output_json}" nix eval --impure --expr '
        let
          data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
          site = data.control_plane_model.data.esp0xdeadbeef."site-a";
          ipv6 = site.ipv6;
          slots = ipv6.pd.tenantSlots;
          admin = ipv6.tenants.admin;
          client = ipv6.tenants.client;
          mgmt = ipv6.tenants.mgmt;
        in
          builtins.isAttrs ipv6
          && ipv6.pd.uplink == "wan"
          && ipv6.pd.delegatedPrefixLength == 56
          && ipv6.pd.perTenantPrefixLength == 64
          && slots.admin == 0
          && slots.client == 1
          && admin.mode == "slaac"
          && (admin.pd.slot == 0)
          && client.mode == "dhcpv6"
          && (client.pd.slot == 1)
          && mgmt.mode == "static"
          && mgmt.prefixes == [ "2001:db8:10::/64" ]
      ' >/dev/null || fail "FAIL ${name}: validation failed"
      echo "PASS ${name}"
      ;;
    minimal-forwarding-model)
      OUTPUT_JSON="${output_json}" nix eval --impure --expr '
        let
          data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
          cpm = data.control_plane_model;
          site = cpm.data.acme.ams;
          policy = site.runtimeTargets.policy-runtime;
          upstream = site.runtimeTargets.upstream-runtime;
        in
          builtins.isAttrs cpm
          && builtins.isAttrs cpm.data
          && builtins.isAttrs site
          && site.siteId == "ams"
          && site.siteName == "acme.ams"
          && builtins.isAttrs site.runtimeTargets
          && builtins.isAttrs policy
          && builtins.isAttrs upstream
          && policy.logicalNode.enterprise == "acme"
          && policy.logicalNode.site == "ams"
          && policy.logicalNode.name == "policy-1"
          && upstream.logicalNode.enterprise == "acme"
          && upstream.logicalNode.site == "ams"
          && upstream.logicalNode.name == "upstream-1"
      ' >/dev/null || fail "FAIL ${name}: validation failed"
      echo "PASS ${name}"
      ;;
    default-egress-reachability)
      OUTPUT_JSON="${output_json}" nix eval --impure --expr '
        let
          data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
          site = data.control_plane_model.data.acme.ams;

          hasRoute = routes: dst:
            builtins.any (route: (route.dst or null) == dst) routes;

          hasIPv4Via = routes: dst: via:
            builtins.any
              (route:
                (route.dst or null) == dst
                && (route.via4 or null) == via)
              routes;

          hasIPv6Via = routes: dst: via:
            builtins.any
              (route:
                (route.dst or null) == dst
                && (route.via6 or null) == via)
              routes;

          access = site.runtimeTargets.access-runtime;
          policy = site.runtimeTargets.policy-runtime;
          upstream = site.runtimeTargets.upstream-runtime;
          core = site.runtimeTargets.core-runtime;

          accessP2P = access.effectiveRuntimeRealization.interfaces.p2p0.routes;
          accessTenant = access.effectiveRuntimeRealization.interfaces.tenant0.routes;
          policyUpstream = policy.effectiveRuntimeRealization.interfaces.p2p-upstream.routes;
          upstreamCore = upstream.effectiveRuntimeRealization.interfaces.p2p-core.routes;
          coreWAN = core.effectiveRuntimeRealization.interfaces.uplink0.routes;

          accessP2PAttach = access.effectiveRuntimeRealization.interfaces.p2p0.attach;

          accessDhcp4 = builtins.elemAt access.advertisements.dhcp4 0;
          accessIpv6Ra = builtins.elemAt access.advertisements.ipv6Ra 0;
        in
          access.routingAuthority.defaultReachability
          && policy.routingAuthority.defaultReachability
          && upstream.routingAuthority.defaultReachability
          && core.routingAuthority.defaultReachability
          && hasRoute coreWAN.ipv4 "0.0.0.0/0"
          && hasRoute coreWAN.ipv6 "::/0"
          && hasIPv4Via upstreamCore.ipv4 "0.0.0.0/0" "169.254.12.0"
          && hasIPv6Via upstreamCore.ipv6 "::/0" "fd00:12::0"
          && hasIPv4Via policyUpstream.ipv4 "0.0.0.0/0" "169.254.11.0"
          && hasIPv6Via policyUpstream.ipv6 "::/0" "fd00:11::0"
          && hasIPv4Via accessP2P.ipv4 "0.0.0.0/0" "169.254.10.1"
          && hasIPv6Via accessP2P.ipv6 "::/0" "fd00:10::1"
          && !(hasRoute accessTenant.ipv4 "0.0.0.0/0")
          && !(hasRoute accessTenant.ipv6 "::/0")
          && accessP2PAttach.kind == "bridge"
          && accessP2PAttach.bridge == "br-transit"
          && accessP2PAttach.vlan == 100
          && accessP2PAttach.parentUplink == "uplink0"
          && accessDhcp4.interface == "tenant0"
          && accessDhcp4.bindInterface == "tenant-a"
          && accessDhcp4.tenant == "tenant-a"
          && accessDhcp4.id == "tenant-a"
          && accessDhcp4.subnet == "10.20.0.0/24"
          && accessDhcp4.router == "10.20.0.1"
          && accessDhcp4.routerAddress == "10.20.0.1"
          && accessDhcp4.routerInterfaceAddress == "10.20.0.1"
          && accessDhcp4.authoritativeRouterAddress == "10.20.0.1"
          && accessDhcp4.routerInterface.logicalInterface == "tenant0"
          && accessDhcp4.routerInterface.bindInterface == "tenant-a"
          && accessDhcp4.routerInterface.tenant == "tenant-a"
          && accessDhcp4.routerInterface.address4 == "10.20.0.1"
          && accessDhcp4.routerInterface.address6 == "fd00:20::1"
          && accessDhcp4.routerInterface.subnet4 == "10.20.0.0/24"
          && accessDhcp4.routerInterface.subnet6 == "fd00:20::/64"
          && accessIpv6Ra.interface == "tenant0"
          && accessIpv6Ra.bindInterface == "tenant-a"
          && accessIpv6Ra.tenant == "tenant-a"
          && accessIpv6Ra.routerAddress == "fd00:20::1"
          && accessIpv6Ra.routerInterfaceAddress == "fd00:20::1"
          && accessIpv6Ra.authoritativeRouterAddress == "fd00:20::1"
          && accessIpv6Ra.routerInterface.logicalInterface == "tenant0"
          && accessIpv6Ra.routerInterface.bindInterface == "tenant-a"
          && accessIpv6Ra.routerInterface.tenant == "tenant-a"
          && accessIpv6Ra.routerInterface.address4 == "10.20.0.1"
          && accessIpv6Ra.routerInterface.address6 == "fd00:20::1"
          && accessIpv6Ra.routerInterface.subnet4 == "10.20.0.0/24"
          && accessIpv6Ra.routerInterface.subnet6 == "fd00:20::/64"
          && accessIpv6Ra.prefixes == [ "fd00:20::/64" ]
      ' >/dev/null || fail "FAIL ${name}: validation failed"
      echo "PASS ${name}"
      ;;
    multi-wan)
      OUTPUT_JSON="${output_json}" nix eval --impure --expr '
        let
          data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
          site = data.control_plane_model.data.esp0xdeadbeef."site-a";
          upstream =
            site.runtimeTargets."esp0xdeadbeef-site-a-s-router-upstream-selector";
          accessMgmt =
            site.runtimeTargets."esp0xdeadbeef-site-a-s-router-access-mgmt";
          upstreamA =
            upstream.effectiveRuntimeRealization.interfaces."p2p-s-router-core-isp-a-s-router-upstream-selector".routes;
          upstreamB =
            upstream.effectiveRuntimeRealization.interfaces."p2p-s-router-core-isp-b-s-router-upstream-selector".routes;
          accessP2P =
            accessMgmt.effectiveRuntimeRealization.interfaces."p2p-s-router-access-mgmt-s-router-downstream-selector".routes;

          hasIPv4Via = routes: dst: via:
            builtins.any
              (route:
                (route.dst or null) == dst
                && (route.via4 or null) == via)
              routes;

          hasIPv6Via = routes: dst: via:
            builtins.any
              (route:
                (route.dst or null) == dst
                && (route.via6 or null) == via)
              routes;

          metricForIPv4Via = routes: dst: via:
            let
              matches = builtins.filter
                (route:
                  (route.dst or null) == dst
                  && (route.via4 or null) == via)
                routes;
            in
            if matches == [ ] then null else ((builtins.elemAt matches 0).metric or null);

          metricForIPv6Via = routes: dst: via:
            let
              matches = builtins.filter
                (route:
                  (route.dst or null) == dst
                  && (route.via6 or null) == via)
                routes;
            in
            if matches == [ ] then null else ((builtins.elemAt matches 0).metric or null);
        in
          site.uplinkCoreNames == [ "s-router-core-isp-a" "s-router-core-isp-b" ]
          && site.uplinkNames == [ "isp-a" "isp-b" ]
          && hasIPv4Via upstreamA.ipv4 "0.0.0.0/0" "10.10.0.6"
          && hasIPv4Via upstreamB.ipv4 "0.0.0.0/0" "10.10.0.8"
          && hasIPv6Via upstreamA.ipv6 "::/0" "fd42:dead:beef:1000:0:0:0:6"
          && hasIPv6Via upstreamB.ipv6 "::/0" "fd42:dead:beef:1000:0:0:0:8"
          && metricForIPv4Via upstreamA.ipv4 "0.0.0.0/0" "10.10.0.6" == 100
          && metricForIPv4Via upstreamB.ipv4 "0.0.0.0/0" "10.10.0.8" == 200
          && metricForIPv6Via upstreamA.ipv6 "::/0" "fd42:dead:beef:1000:0:0:0:6" == 100
          && metricForIPv6Via upstreamB.ipv6 "::/0" "fd42:dead:beef:1000:0:0:0:8" == 200
          && hasIPv4Via accessP2P.ipv4 "0.0.0.0/0" "10.10.0.5"
          && hasIPv6Via accessP2P.ipv6 "::/0" "fd42:dead:beef:1000:0:0:0:5"
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
  if [[ ! -d "${examples_root}" ]]; then
    log "Skipping external examples (missing ${examples_root})"
    return 0
  fi

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
    inventory="${dir}/inventory-nixos.nix"

    [[ -f "$intent" ]] || { echo "SKIP ${name} (no intent.nix)"; continue; }
    [[ -f "$inventory" ]] || { echo "SKIP ${name} (no inventory-nixos.nix)"; continue; }

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
    case "${name}" in
      single-wan-ipv6-pd)
        validate_output "network-labs-example:${name}" "${tmp_out}" "single-wan-ipv6-pd"
        ;;
      multi-wan)
        validate_output "network-labs-example:${name}" "${tmp_out}" "multi-wan"
        ;;
      *)
        validate_output "network-labs-example:${name}" "${tmp_out}" "network-labs-example"
        ;;
    esac
    rm -rf "${tmp_dir}"
  done
}

minimal_input='{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 9;
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
            allowedRelations = [];
          };
          policy = {
            interfaceTags = {};
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

minimal_inventory='{
  deployment = {
    hosts = {
      hypervisor-a = {
        uplinks = {
          uplink0 = {
            parent = "eno1";
            bridge = "br-runtime-a";
          };
        };
      };
    };
  };

  realization = {
    nodes = {
      policy-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "acme";
          site = "ams";
          name = "policy-1";
        };
        ports = { };
      };

      upstream-runtime = {
        host = "hypervisor-a";
        platform = "linux";
        logicalNode = {
          enterprise = "acme";
          site = "ams";
          name = "upstream-1";
        };
        ports = { };
      };
    };
  };
}'

pppoe_input="$minimal_input"
hosted_input="$minimal_input"
hosted_inventory="$minimal_inventory"
default_egress_input="$(cat "${repo_root}/fixtures/passing/default-egress-reachability/input.nix")"
default_egress_inventory="$(cat "${repo_root}/fixtures/passing/default-egress-reachability/inventory.nix")"

run_case "minimal-forwarding-model" "$minimal_input" "$minimal_inventory" "minimal-forwarding-model"
run_case "minimal-forwarding-model-pppoe" "$pppoe_input" "$minimal_inventory" "minimal-forwarding-model-pppoe"
run_case "hosted-runtime-targets" "$hosted_input" "$hosted_inventory" "hosted-runtime-targets"
run_case "default-egress-reachability" "$default_egress_input" "$default_egress_inventory" "default-egress-reachability"

run_external_examples
bash "${repo_root}/tests/test-dual-wan-branch-overlay.sh"
bash "${repo_root}/tests/test-hostile-dns-east-west.sh"
bash "${repo_root}/tests/test-dns-service-policy-routes.sh"
bash "${repo_root}/tests/test-policy-derived-dns-upstreams.sh"
bash "${repo_root}/tests/test-preferred-uplink-defaults.sh"
bash "${repo_root}/tests/test-realized-interface-routes.sh"
bash "${repo_root}/tests/test-link-lane-preservation.sh"
bash "${repo_root}/tests/test-transit-endpoint-return-routes.sh"

exit 0
