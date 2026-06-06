#!/usr/bin/env bash
# GAMP-ID: FS-550-HDS-010-SDS-010-SMS-050
# GAMP-ID: FS-570-HDS-010-SDS-010-SMS-010
# GAMP-ID: FS-570-HDS-010-SDS-010-SMS-020
# GAMP-ID: FS-880-HDS-010-SDS-010-SMS-020
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
system="${NIX_SYSTEM:-$(nix eval --impure --raw --expr 'builtins.currentSystem')}"
fixture_dir="${repo_root}/fixtures/passing/default-egress-reachability"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

input_path="${fixture_dir}/input.nix"
inventory_path="${tmp_dir}/inventory.nix"
missing_classes_inventory_path="${tmp_dir}/missing-denied-classes-inventory.nix"
implicit_public_fallback_inventory_path="${tmp_dir}/implicit-public-fallback-inventory.nix"
missing_fallback_target_inventory_path="${tmp_dir}/missing-fallback-target-inventory.nix"
missing_leak_prevention_inventory_path="${tmp_dir}/missing-leak-prevention-inventory.nix"
cross_tenant_public_fallback_inventory_path="${tmp_dir}/cross-tenant-public-fallback-inventory.nix"
output_json="${tmp_dir}/cpm.json"
missing_classes_stderr="${tmp_dir}/missing-denied-classes.stderr"
implicit_public_fallback_stderr="${tmp_dir}/implicit-public-fallback.stderr"
missing_fallback_target_stderr="${tmp_dir}/missing-fallback-target.stderr"
missing_leak_prevention_stderr="${tmp_dir}/missing-leak-prevention.stderr"
cross_tenant_public_fallback_stderr="${tmp_dir}/cross-tenant-public-fallback.stderr"

cat >"${inventory_path}" <<EOF
let
  base = import ${fixture_dir}/inventory.nix;
  modeledRouterSelfDns = {
    implementation = "unbound";
    listen = [ ];
    allowFrom = [ ];
    forwarders = [ "1.1.1.1" ];
    deniedResolverCidrs = [ ];
    killSwitch.blockPublicResolvers = false;
    allowedUpstreamClasses = [ "local-access" "explicit-egress-default" ];
  };
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services = (base.realization.nodes.access-runtime.services or { }) // {
          dns = {
            implementation = "unbound";
            listen = [ "10.20.0.1" "fd00:20::1" ];
            allowFrom = [ "10.20.0.0/24" "fd00:20::/64" ];
            forwarders = [ "1.1.1.1" ];
            deniedResolverCidrs = [ ];
            killSwitch.blockPublicResolvers = false;
            allowedUpstreamClasses = [ "local-access" "explicit-egress-default" ];
            namespaceFallback = {
              defaultPublicRecursionFallback = false;
              decisions = [
                {
                  requesterScope = "tenant-a";
                  namespace = "tenant-a.lan.";
                  allowedRecordClasses = [ "A" "AAAA" ];
                  deniedRecordClasses = [ "PUBLIC-RECURSION" ];
                  failedAnswerReason = "missing-record";
                  action = "block";
                  publicRecursionFallback = false;
                  leakPrevention = "fail-closed";
                }
                {
                  requesterScope = "tenant-b";
                  namespace = "tenant-a.lan.";
                  allowedRecordClasses = [ "A" "AAAA" ];
                  deniedRecordClasses = [ "A" "AAAA" "PUBLIC-RECURSION" ];
                  failedAnswerReason = "denied-requester-scope";
                  action = "deny";
                  publicRecursionFallback = false;
                  leakPrevention = "terminal-denial";
                }
                {
                  requesterScope = "tenant-a-guest";
                  namespace = "tenant-a.lan.";
                  allowedRecordClasses = [ "A" "AAAA" ];
                  deniedRecordClasses = [ "LOCAL-AUTHORITY" ];
                  failedAnswerReason = "missing-record";
                  action = "fallback";
                  fallbackTarget = "guest-recursive-dns";
                  publicRecursionFallback = true;
                  leakPrevention = "explicit-split-horizon-fallback";
                }
              ];
            };
          };
        };
      };
      globex-nyc-access-runtime = base.realization.nodes.globex-nyc-access-runtime // {
        services = (base.realization.nodes.globex-nyc-access-runtime.services or { }) // {
          dns = modeledRouterSelfDns;
        };
      };
      globex-lon-access-runtime = base.realization.nodes.globex-lon-access-runtime // {
        services = (base.realization.nodes.globex-lon-access-runtime.services or { }) // {
          dns = modeledRouterSelfDns;
        };
      };
    };
  };
}
EOF

cat >"${missing_classes_inventory_path}" <<EOF
let
  base = import ${inventory_path};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services = base.realization.nodes.access-runtime.services // {
          dns = base.realization.nodes.access-runtime.services.dns // {
            namespaceFallback = base.realization.nodes.access-runtime.services.dns.namespaceFallback // {
              decisions = [
                {
                  requesterScope = "tenant-a";
                  namespace = "tenant-a.lan.";
                  allowedRecordClasses = [ "A" ];
                  failedAnswerReason = "missing-record";
                  action = "block";
                  publicRecursionFallback = false;
                  leakPrevention = "fail-closed";
                }
              ];
            };
          };
        };
      };
    };
  };
}
EOF

cat >"${implicit_public_fallback_inventory_path}" <<EOF
let
  base = import ${inventory_path};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services = base.realization.nodes.access-runtime.services // {
          dns = base.realization.nodes.access-runtime.services.dns // {
            namespaceFallback = base.realization.nodes.access-runtime.services.dns.namespaceFallback // {
              decisions = [
                {
                  requesterScope = "tenant-a";
                  namespace = "tenant-a.lan.";
                  allowedRecordClasses = [ "A" ];
                  deniedRecordClasses = [ "PUBLIC-RECURSION" ];
                  failedAnswerReason = "missing-record";
                  action = "block";
                  publicRecursionFallback = true;
                  leakPrevention = "fail-closed";
                }
              ];
            };
          };
        };
      };
    };
  };
}
EOF

cat >"${missing_fallback_target_inventory_path}" <<EOF
let
  base = import ${inventory_path};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services = base.realization.nodes.access-runtime.services // {
          dns = base.realization.nodes.access-runtime.services.dns // {
            namespaceFallback = base.realization.nodes.access-runtime.services.dns.namespaceFallback // {
              decisions = [
                {
                  requesterScope = "tenant-a-guest";
                  namespace = "tenant-a.lan.";
                  allowedRecordClasses = [ "A" ];
                  deniedRecordClasses = [ "LOCAL-AUTHORITY" ];
                  failedAnswerReason = "missing-record";
                  action = "fallback";
                  publicRecursionFallback = true;
                  leakPrevention = "explicit-split-horizon-fallback";
                }
              ];
            };
          };
        };
      };
    };
  };
}
EOF

cat >"${missing_leak_prevention_inventory_path}" <<EOF
let
  base = import ${inventory_path};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services = base.realization.nodes.access-runtime.services // {
          dns = base.realization.nodes.access-runtime.services.dns // {
            namespaceFallback = base.realization.nodes.access-runtime.services.dns.namespaceFallback // {
              decisions = [
                {
                  requesterScope = "tenant-a-guest";
                  namespace = "tenant-a.lan.";
                  allowedRecordClasses = [ "A" ];
                  deniedRecordClasses = [ "LOCAL-AUTHORITY" ];
                  failedAnswerReason = "missing-record";
                  action = "fallback";
                  fallbackTarget = "guest-recursive-dns";
                  publicRecursionFallback = true;
                }
              ];
            };
          };
        };
      };
    };
  };
}
EOF

cat >"${cross_tenant_public_fallback_inventory_path}" <<EOF
let
  base = import ${inventory_path};
in
base // {
  realization = base.realization // {
    nodes = base.realization.nodes // {
      access-runtime = base.realization.nodes.access-runtime // {
        services = base.realization.nodes.access-runtime.services // {
          dns = base.realization.nodes.access-runtime.services.dns // {
            namespaceFallback = base.realization.nodes.access-runtime.services.dns.namespaceFallback // {
              decisions = [
                {
                  requesterScope = "tenant-b";
                  namespace = "tenant-a.lan.";
                  allowedRecordClasses = [ "A" ];
                  deniedRecordClasses = [ "A" "PUBLIC-RECURSION" ];
                  failedAnswerReason = "denied-requester-scope";
                  action = "fallback";
                  fallbackTarget = "public-recursive-dns";
                  publicRecursionFallback = true;
                  leakPrevention = "cross-tenant-public-fallback";
                }
              ];
            };
          };
        };
      };
    };
  };
}
EOF

if nix eval --impure --json --expr "
  let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${input_path};
    inventory = import ${missing_classes_inventory_path};
  in
    builder { inherit input inventory; }
" >/dev/null 2>"${missing_classes_stderr}"; then
  echo "FAIL dns-namespace-fallback-contract: missing deniedRecordClasses unexpectedly evaluated" >&2
  exit 1
fi

if ! grep -Fq "services.dns.namespaceFallback.decisions[*].deniedRecordClasses" "${missing_classes_stderr}"; then
  echo "FAIL dns-namespace-fallback-contract: missing deniedRecordClasses failed without path-specific error" >&2
  cat "${missing_classes_stderr}" >&2
  exit 1
fi

if nix eval --impure --json --expr "
  let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${input_path};
    inventory = import ${missing_fallback_target_inventory_path};
  in
    builder { inherit input inventory; }
" >/dev/null 2>"${missing_fallback_target_stderr}"; then
  echo "FAIL dns-namespace-fallback-contract: fallback without target unexpectedly evaluated" >&2
  exit 1
fi

if ! grep -Fq "services.dns.namespaceFallback.decisions[*].fallbackTarget" "${missing_fallback_target_stderr}"; then
  echo "FAIL dns-namespace-fallback-contract: missing fallback target failed without path-specific error" >&2
  cat "${missing_fallback_target_stderr}" >&2
  exit 1
fi

if nix eval --impure --json --expr "
  let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${input_path};
    inventory = import ${missing_leak_prevention_inventory_path};
  in
    builder { inherit input inventory; }
" >/dev/null 2>"${missing_leak_prevention_stderr}"; then
  echo "FAIL dns-namespace-fallback-contract: fallback without leakPrevention unexpectedly evaluated" >&2
  exit 1
fi

if ! grep -Fq "services.dns.namespaceFallback.decisions[*].leakPrevention" "${missing_leak_prevention_stderr}"; then
  echo "FAIL dns-namespace-fallback-contract: missing leakPrevention failed without path-specific error" >&2
  cat "${missing_leak_prevention_stderr}" >&2
  exit 1
fi

if nix eval --impure --json --expr "
  let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${input_path};
    inventory = import ${implicit_public_fallback_inventory_path};
  in
    builder { inherit input inventory; }
" >/dev/null 2>"${implicit_public_fallback_stderr}"; then
  echo "FAIL dns-namespace-fallback-contract: implicit public recursion fallback unexpectedly evaluated" >&2
  exit 1
fi

if ! grep -Fq "services.dns.namespaceFallback.decisions[*].publicRecursionFallback" "${implicit_public_fallback_stderr}"; then
  echo "FAIL dns-namespace-fallback-contract: implicit public fallback failed without path-specific error" >&2
  cat "${implicit_public_fallback_stderr}" >&2
  exit 1
fi

if nix eval --impure --json --expr "
  let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${input_path};
    inventory = import ${cross_tenant_public_fallback_inventory_path};
  in
    builder { inherit input inventory; }
" >/dev/null 2>"${cross_tenant_public_fallback_stderr}"; then
  echo "FAIL dns-namespace-fallback-contract: cross-tenant public fallback unexpectedly evaluated" >&2
  exit 1
fi

if ! grep -Fq "services.dns.namespaceFallback.decisions[*].publicRecursionFallback" "${cross_tenant_public_fallback_stderr}"; then
  echo "FAIL dns-namespace-fallback-contract: cross-tenant public fallback failed without path-specific error" >&2
  cat "${cross_tenant_public_fallback_stderr}" >&2
  exit 1
fi

nix eval --impure --json --expr "
  let
    flake = builtins.getFlake (toString ${repo_root});
    builder = flake.lib.${system}.build;
    input = import ${input_path};
    inventory = import ${inventory_path};
  in
    builder { inherit input inventory; }
" >"${output_json}"

OUTPUT_JSON="${output_json}" nix eval --impure --expr '
  let
    data = builtins.fromJSON (builtins.readFile (builtins.getEnv "OUTPUT_JSON"));
    dns = data.control_plane_model.data.acme.ams.runtimeTargets.access-runtime.services.dns;
    fallback = dns.namespaceFallback or null;
    decisions = fallback.decisions or [ ];
    byReason = reason:
      builtins.filter (decision: (decision.failedAnswerReason or null) == reason) decisions;
    missingRecord = builtins.head (byReason "missing-record");
    deniedScope = builtins.head (byReason "denied-requester-scope");
    fallbackDecision =
      builtins.head (
        builtins.filter
          (decision: (decision.action or null) == "fallback" && (decision.requesterScope or null) == "tenant-a-guest")
          decisions
      );
  in
    fallback != null
    && dns.forwarders == [ "1.1.1.1" ]
    && dns.allowedUpstreamClasses == [ "explicit-egress-default" "local-access" ]
    && fallback.defaultPublicRecursionFallback == false
    && builtins.length decisions == 3
    && missingRecord.action == "block"
    && missingRecord.publicRecursionFallback == false
    && missingRecord.deniedRecordClasses == [ "PUBLIC-RECURSION" ]
    && missingRecord.deniedClasses == [ "PUBLIC-RECURSION" ]
    && missingRecord.leakPrevention == "fail-closed"
    && deniedScope.action == "deny"
    && deniedScope.publicRecursionFallback == false
    && deniedScope.deniedClasses == [ "A" "AAAA" "PUBLIC-RECURSION" ]
    && !(deniedScope ? fallbackTarget)
    && deniedScope.leakPrevention == "terminal-denial"
    && fallbackDecision.allowedRecordClasses == [ "A" "AAAA" ]
    && fallbackDecision.deniedRecordClasses == [ "LOCAL-AUTHORITY" ]
    && fallbackDecision.deniedClasses == [ "LOCAL-AUTHORITY" ]
    && fallbackDecision.fallbackTarget == "guest-recursive-dns"
    && fallbackDecision.publicRecursionFallback == true
    && fallbackDecision.leakPrevention == "explicit-split-horizon-fallback"
' >/dev/null || {
  echo "FAIL dns-namespace-fallback-contract: CPM did not preserve explicit fail-closed namespace fallback decisions" >&2
  exit 1
}

echo "PASS dns-namespace-fallback-contract"
