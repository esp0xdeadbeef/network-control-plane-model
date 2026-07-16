#!/usr/bin/env bash
# GAMP-ID: FS-310-HDS-040-SDS-010-SMS-170
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/tests/lib/direct-test-guard.sh"
source "${repo_root}/tests/lib/pinned-paths.sh"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd nix
require_cmd python3

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"
intent_path="${hat_dir}/intent.nix"
nixos_output="${tmp_dir}/nixos-cpm.json"
clab_output="${tmp_dir}/clab-cpm.json"

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run \
    --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    "${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory}" \
    "${output}" >/dev/null
}

validate_origin_trace() {
  local input="$1"
  local label="$2"
  local mode="${3:-verbose}"

  python3 - "$input" "$label" "$mode" <<'PY'
import json
import sys

TRACE = "FS-310-HDS-040-SDS-010-SMS-170"
path, label, mode = sys.argv[1:4]


def is_obj(value):
    return isinstance(value, dict)


def is_non_empty_string(value):
    return isinstance(value, str) and value != ""


def is_non_empty_list(value):
    return isinstance(value, list) and len(value) > 0


def clean(value):
    return value.split("/", 1)[0] if isinstance(value, str) else value


def iter_targets(model):
    data = model.get("control_plane_model", {}).get("data", {})
    for enterprise_name, enterprise in data.items():
        if not isinstance(enterprise, dict):
            continue
        for site_name, site in enterprise.items():
            if not isinstance(site, dict):
                continue
            targets = site.get("runtimeTargets", {})
            if not isinstance(targets, dict):
                continue
            for target_name, target in targets.items():
                if isinstance(target, dict):
                    yield enterprise_name, site_name, target_name, target


def relation_handoff_ok(rule):
    relation_id = rule.get("relationId")
    traversal = rule.get("policyPointTraversal")
    if not is_non_empty_string(relation_id):
        return False
    if not is_non_empty_string(rule.get("trafficType")):
        return False
    if not is_non_empty_string(rule.get("direction")):
        return False
    if not is_obj(rule.get("from")) or not is_obj(rule.get("to")):
        return False
    if not is_obj(rule.get("relationCardinality")):
        return False
    if not is_obj(rule.get("sourceScope")):
        return False
    if not is_obj(rule.get("destinationScope")):
        return False
    if not is_obj(rule.get("candidateEgress")):
        return False
    if not is_obj(traversal):
        return False
    if traversal.get("relationId") != relation_id:
        return False
    if traversal.get("action") != rule.get("action"):
        return False
    if traversal.get("direction") != rule.get("direction"):
        return False
    if traversal.get("sourceInterface") != rule.get("fromInterface"):
        return False
    if traversal.get("destinationInterface") != rule.get("toInterface"):
        return False
    return True


def dns_service_egress_ok(rule):
    intent = rule.get("intent")
    return (
        is_obj(intent)
        and intent.get("kind") == "dns-service-public-egress"
        and intent.get("source") == "dns-service"
        and rule.get("action") == "accept"
        and rule.get("trafficType") == "dns"
        and rule.get("comment") == "allow-dns-service-egress"
        and is_non_empty_list(rule.get("sourcePrefixes"))
        and is_non_empty_string(rule.get("fromInterface"))
        and is_non_empty_string(rule.get("toInterface"))
    )


def delegated_public_egress_ok(rule):
    intent = rule.get("intent")
    has_source_scope = is_non_empty_list(rule.get("sourcePrefixes")) or is_non_empty_list(rule.get("sourceFiles"))
    return (
        is_obj(intent)
        and intent.get("kind") == "delegated-public-egress"
        and intent.get("source") == "tenant-prefix-owner"
        and intent.get("stage") == "core-transit-to-provider-overlay"
        and rule.get("action") == "accept"
        and is_non_empty_string(rule.get("fromInterface"))
        and is_non_empty_string(rule.get("toInterface"))
        and has_source_scope
    )


def forwarding_rule_origin(rule):
    if relation_handoff_ok(rule):
        return "relation-handoff"
    if dns_service_egress_ok(rule):
        return "dns-service-public-egress"
    if delegated_public_egress_ok(rule):
        return "delegated-public-egress"
    return None


def isolation_endpoint_ok(endpoint):
    # A per-endpoint dedicated-link isolation proof. Presence of a backingRef,
    # scope, or generated relation label is NOT enough: the endpoint must be a
    # dedicated, non-external surface backed by a modeled fabric link or a
    # modeled session peer.
    return (
        is_obj(endpoint)
        and endpoint.get("admissible") is True
        and endpoint.get("dedicated") is True
        and endpoint.get("external") is False
        and is_obj(endpoint.get("modeledPeer"))
        and endpoint["modeledPeer"].get("kind") in ("fabric-link", "modeled-session-peer")
    )


def transport_authority_ok(rule):
    # Policy authority for an interface-pair transport accept. Topology
    # provenance (relationId, comment, intent.kind, backingRefs, scopes,
    # policyPointTraversal) proves origin but never authorizes packets. Only a
    # complete dedicated-link isolation record with both endpoints proven
    # dedicated, non-external, and backed by a modeled peer authorizes the
    # transport. An external surface classified as core mesh (the 2026-07-15
    # production ppp0/ens3 case) fails here.
    authority = rule.get("transportAuthority")
    if not is_obj(authority):
        return False
    if authority.get("basis") != "dedicated-link-isolation":
        return False
    if authority.get("provenanceIsAuthority") is not False:
        return False
    return isolation_endpoint_ok(authority.get("from")) and isolation_endpoint_ok(authority.get("to"))


def has_enforceable_match(rule):
    if is_non_empty_list(rule.get("matches")):
        return True
    if is_non_empty_list(rule.get("sourcePrefixes")) or is_non_empty_list(rule.get("sourceFiles")):
        return True
    traffic = rule.get("trafficType")
    return is_non_empty_string(traffic) and traffic != "any"


def is_reverse_rule(rule):
    if rule.get("returnRule") is True:
        return True
    direction = rule.get("direction")
    return is_non_empty_string(direction) and "reverse" in direction


def is_stateful_return(rule):
    state = rule.get("connectionState")
    return is_non_empty_string(state) and "established" in state


def validate_nat_contract(target_ctx, nat_intent, violations):
    if not nat_intent.get("enabled"):
        return 0
    records = nat_intent.get("translationRecords")
    if not is_non_empty_list(records):
        violations.append(f"{target_ctx}: enabled natIntent has no translationRecords")
        return 0
    ok_records = 0
    for idx, record in enumerate(records):
        egress = record.get("egressSurface")
        boundary = record.get("tenantIsolationBoundary")
        consumers = record.get("consumers")
        if not (
            is_non_empty_string(record.get("mode"))
            and is_non_empty_string(record.get("trafficClass"))
            and is_non_empty_list(record.get("sourceScope"))
            and is_obj(egress)
            and is_non_empty_list(egress.get("selectedUplinks"))
            and is_non_empty_list(egress.get("selectedUplinkInterfaces"))
            and is_obj(boundary)
            and boundary.get("kind") == "tenant-source-prefix"
            and is_non_empty_list(boundary.get("sourcePrefixes"))
            and is_obj(record.get("returnBehavior"))
            and isinstance(consumers, list)
            and {"routing", "firewall", "renderer"}.issubset(set(consumers))
        ):
            violations.append(f"{target_ctx}: natIntent.translationRecords[{idx}] lacks explicit NAT origin/scope contract")
        else:
            ok_records += 1
    return ok_records


def validate_dns_contract(target_ctx, dns, violations):
    forwarders = dns.get("forwarders")
    if not is_non_empty_list(forwarders):
        return 0
    route_contracts = dns.get("routeContracts")
    matrix = dns.get("policyMatrix")
    classifications = dns.get("publicDnsTrafficClassifications")
    kill_switch = dns.get("killSwitch")
    if not is_non_empty_list(route_contracts):
        violations.append(f"{target_ctx}: DNS forwarders exist without routeContracts")
        return 0
    contract_map = {clean(entry.get("dst")): entry for entry in route_contracts if isinstance(entry, dict)}
    missing = []
    for forwarder in forwarders:
        entry = contract_map.get(clean(forwarder))
        if not isinstance(entry, dict) or entry.get("source") != "dns-service":
            missing.append(forwarder)
    if missing:
        violations.append(f"{target_ctx}: DNS forwarders missing dns-service routeContracts: {', '.join(missing)}")
    if not is_non_empty_list(matrix):
        violations.append(f"{target_ctx}: DNS contract has no policyMatrix")
    if not is_non_empty_list(classifications):
        violations.append(f"{target_ctx}: DNS contract has no publicDnsTrafficClassifications")
    if not is_obj(kill_switch) or kill_switch.get("allowPublicResolverFallback") is not False:
        violations.append(f"{target_ctx}: DNS killSwitch does not explicitly deny public resolver fallback")
    if is_non_empty_list(matrix) and is_non_empty_list(classifications) and not missing:
        return 1
    return 0


with open(path, "r", encoding="utf-8") as handle:
    model = json.load(handle)

violations = []
rule_count = 0
origin_counts = {}
core_mesh_count = 0
authority_verified_mesh = 0
nat_record_count = 0
dns_contract_count = 0

for enterprise_name, site_name, target_name, target in iter_targets(model):
    target_ctx = f"{enterprise_name}.{site_name}.{target_name}"
    for rule in target.get("forwardingIntent", {}).get("rules", []) or []:
        rule_count += 1
        origin = forwarding_rule_origin(rule)
        if origin is None:
            violations.append(
                f"{target_ctx}: {TRACE} CPM-invented forwarding rule missing forwarding-model origin: "
                f"{rule.get('fromInterface', '<missing>')}->{rule.get('toInterface', '<missing>')}"
            )
            continue
        origin_counts[origin] = origin_counts.get(origin, 0) + 1
        intent = rule.get("intent") if isinstance(rule.get("intent"), dict) else {}
        if intent.get("kind") == "core-transit-mesh":
            core_mesh_count += 1
            if transport_authority_ok(rule):
                authority_verified_mesh += 1
            else:
                violations.append(
                    f"{target_ctx}: {TRACE} core-transit-mesh rule {rule.get('fromInterface', '?')}->{rule.get('toInterface', '?')} "
                    "carries topology provenance labels but lacks a valid transportAuthority dedicated-link-isolation record; "
                    "interface-pair transport without enforceable packet matches requires complete dedicated-isolation authority"
                )
        # Reverse-accept safety: a reverse rule with trafficType=any must be
        # either a stateful established,related return or carry its own
        # transportAuthority record. An unqualified symmetric reverse accept
        # is never authorized by the forward relation alone.
        if (
            rule.get("action") == "accept"
            and rule.get("trafficType") == "any"
            and is_reverse_rule(rule)
            and not is_stateful_return(rule)
            and not transport_authority_ok(rule)
        ):
            violations.append(
                f"{target_ctx}: {TRACE} reverse new-flow accept {rule.get('fromInterface', '?')}->{rule.get('toInterface', '?')} "
                "is a state-unqualified symmetric reverse without a distinct modeled reverse relation; "
                "reverse new-flow authority requires a distinct forwarding-model relation"
            )
    nat_record_count += validate_nat_contract(target_ctx, target.get("natIntent", {}) or {}, violations)
    dns_contract_count += validate_dns_contract(target_ctx, target.get("services", {}).get("dns", {}) or {}, violations)

if rule_count == 0:
    violations.append(f"{label}: no forwardingIntent rules were present; test would be vacuous")
if core_mesh_count == 0:
    violations.append(f"{label}: no core-transit-mesh forwarding-origin rules were present")
if authority_verified_mesh == 0 and core_mesh_count > 0:
    violations.append(f"{label}: all {core_mesh_count} core-transit-mesh rules failed transport-authority verification")
if nat_record_count == 0:
    violations.append(f"{label}: no explicit NAT translation records were validated")
if dns_contract_count == 0:
    violations.append(f"{label}: no explicit DNS route contracts were validated")

summary = {
    "trace": TRACE,
    "label": label,
    "forwardingRules": rule_count,
    "originCounts": origin_counts,
    "coreTransitMeshRules": core_mesh_count,
    "authorityVerifiedCoreMesh": authority_verified_mesh,
    "natTranslationRecords": nat_record_count,
    "dnsContracts": dns_contract_count,
    "violations": violations[:8],
}

if violations:
    print(json.dumps(summary, indent=2), file=sys.stderr)
    sys.exit(1)

if mode != "quiet":
    print(json.dumps(summary, indent=2))
PY
}

inject_invented_rule() {
  local input="$1"
  local output="$2"

  python3 - "$input" "$output" <<'PY'
import copy
import json
import sys

src, dest = sys.argv[1:3]
with open(src, "r", encoding="utf-8") as handle:
    model = json.load(handle)

for enterprise in model["control_plane_model"]["data"].values():
    for site in enterprise.values():
        for target in site.get("runtimeTargets", {}).values():
            rules = target.setdefault("forwardingIntent", {}).setdefault("rules", [])
            rules.append({
                "action": "accept",
                "trafficType": "any",
                "fromInterface": "seeded-lan",
                "toInterface": "seeded-wan",
                "comment": "seeded bare firewall rule without forwarding-model origin"
            })
            with open(dest, "w", encoding="utf-8") as output:
                json.dump(model, output)
            sys.exit(0)

raise SystemExit("no runtime target available for seeded negative")
PY
}

# Inject one of the three label-recovery negatives required by the SMS:
#   labels-only  : complete topology provenance (relationId, intent.kind,
#                  scopes, policyPointTraversal) but NO transportAuthority.
#   external     : full transportAuthority record whose destination endpoint is
#                  an external surface (the 2026-07-15 ppp0/ens3 production
#                  case) — external surfaces are never core-transit authority.
#   reverse      : a state-unqualified symmetric reverse accept sharing the
#                  forward relation id, with no distinct modeled reverse
#                  relation and no established,related connection state.
# Every variant carries complete origin labels so the scan must reject on
# authority, not on missing origin.
inject_label_recovery_negative() {
  local input="$1"
  local output="$2"
  local variant="$3"

  python3 - "$input" "$output" "$variant" <<'PY'
import json
import sys

src, dest, variant = sys.argv[1:4]
with open(src, "r", encoding="utf-8") as handle:
    model = json.load(handle)


def handoff_skeleton(from_if, to_if, relation_id, direction):
    # A fully labeled relation-handoff rule: passes forwarding-model origin
    # classification purely on topology provenance labels.
    return {
        "action": "accept",
        "trafficType": "any",
        "fromInterface": from_if,
        "toInterface": to_if,
        "relationId": relation_id,
        "comment": relation_id,
        "direction": direction,
        "from": {"logicalInterface": from_if},
        "to": {"logicalInterface": to_if},
        "relationCardinality": {"unit": "core-transit-mesh-rule"},
        "sourceScope": {"logicalInterface": from_if},
        "destinationScope": {"logicalInterface": to_if},
        "candidateEgress": {"logicalInterface": to_if},
        "intent": {"kind": "core-transit-mesh", "source": "forwarding-model-transit"},
        "policyPointTraversal": {
            "relationId": relation_id,
            "action": "accept",
            "direction": direction,
            "sourceInterface": from_if,
            "destinationInterface": to_if,
        },
    }


def isolation_proof(surface, external):
    return {
        "admissible": not external,
        "dedicated": True,
        "external": external,
        "surface": surface,
        "modeledPeer": {"kind": "modeled-session-peer", "peerRuntimeTarget": "peer-" + surface},
    }


if variant == "labels-only":
    rule = handoff_skeleton("ens3", "ppp0", "core-transit-mesh--ens3--ppp0", "core-transit-mesh")
    # No transportAuthority at all — labels must not recover.
elif variant == "external":
    rule = handoff_skeleton("ens3", "ppp0", "core-transit-mesh--ens3--ppp0", "core-transit-mesh")
    rule["transportAuthority"] = {
        "basis": "dedicated-link-isolation",
        "provenanceIsAuthority": False,
        "from": isolation_proof("ens3", external=True),
        "to": isolation_proof("ppp0", external=False),
    }
elif variant == "reverse":
    rule = handoff_skeleton("ppp0", "ens3", "core-transit-mesh--ens3--ppp0", "core-transit-mesh-reverse")
    rule["returnRule"] = True
    # No connectionState, no transportAuthority: a bare symmetric reverse.
else:
    raise SystemExit("unknown seeded-negative variant: " + variant)

for enterprise in model["control_plane_model"]["data"].values():
    for site in enterprise.values():
        for target in site.get("runtimeTargets", {}).values():
            rules = target.setdefault("forwardingIntent", {}).setdefault("rules", [])
            rules.append(rule)
            with open(dest, "w", encoding="utf-8") as output:
                json.dump(model, output)
            sys.exit(0)

raise SystemExit("no runtime target available for seeded negative")
PY
}

build_cpm "${hat_dir}/inventory-nixos.nix" "${nixos_output}"
build_cpm "${hat_dir}/inventory-clab.nix" "${clab_output}"

validate_origin_trace "${nixos_output}" "nixos"
validate_origin_trace "${clab_output}" "clab"

seeded="${tmp_dir}/seeded-cpm-invented-rule.json"
inject_invented_rule "${nixos_output}" "${seeded}"
if validate_origin_trace "${seeded}" "seeded-negative" quiet 2>"${tmp_dir}/seeded.stderr"; then
  echo "FAIL FS-310-HDS-040-SDS-010-SMS-170: seeded CPM-invented rule was accepted" >&2
  exit 1
fi
if ! grep -Fq "CPM-invented forwarding rule missing forwarding-model origin" "${tmp_dir}/seeded.stderr"; then
  echo "FAIL FS-310-HDS-040-SDS-010-SMS-170: seeded negative did not report the missing forwarding-model origin diagnostic" >&2
  cat "${tmp_dir}/seeded.stderr" >&2
  exit 1
fi
echo "PASS FS-310-HDS-040-SDS-010-SMS-170 seeded negative: CPM-invented rule rejected"

# Three label-recovery negatives: labels must not recover any of them.
assert_label_negative() {
  local variant="$1"
  local expect="$2"
  local seeded_file="${tmp_dir}/seeded-${variant}.json"
  local err_file="${tmp_dir}/seeded-${variant}.stderr"
  inject_label_recovery_negative "${nixos_output}" "${seeded_file}" "${variant}"
  if validate_origin_trace "${seeded_file}" "seeded-${variant}" quiet 2>"${err_file}"; then
    echo "FAIL FS-310-HDS-040-SDS-010-SMS-170: seeded ${variant} negative was accepted (labels recovered it)" >&2
    exit 1
  fi
  if ! grep -Fq "${expect}" "${err_file}"; then
    echo "FAIL FS-310-HDS-040-SDS-010-SMS-170: seeded ${variant} negative did not report the expected diagnostic" >&2
    cat "${err_file}" >&2
    exit 1
  fi
  echo "PASS FS-310-HDS-040-SDS-010-SMS-170 seeded negative: ${variant} rejected (labels did not recover)"
}

assert_label_negative "labels-only" "lacks a valid transportAuthority dedicated-link-isolation record"
assert_label_negative "external" "lacks a valid transportAuthority dedicated-link-isolation record"
assert_label_negative "reverse" "state-unqualified symmetric reverse without a distinct modeled reverse relation"

validate_origin_trace "${nixos_output}" "nixos" quiet
validate_origin_trace "${clab_output}" "clab" quiet

echo "PASS FS-310-HDS-040-SDS-010-SMS-170 cpm-forwarding-intent-preservation"
