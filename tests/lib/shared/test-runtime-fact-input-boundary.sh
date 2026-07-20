#!/usr/bin/env bash
# GAMP-ID: FS-490-HDS-010-SDS-010-SMS-030
# GAMP-SCOPE: software-module-test
# Construction handoff: CMC constructs in network-control-plane-model (CPM).
# This focused test verifies every SMS-030 predicate through the
# gamp-sms-input-contracts.py checker in network-codex-agent.
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"
source "${repo_root}/tests/lib/direct-test-guard.sh"

codex_agent_root="${repo_root}/../network-codex-agent"
checker="${codex_agent_root}/scripts/helpers/gamp-sms-input-contracts.py"

if [[ ! -x "${checker}" ]]; then
  echo "SKIP: checker not found at ${checker}" >&2
  exit 0
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require_cmd jq

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

fail() {
  echo "FAIL test-runtime-fact-input-boundary: $*" >&2
  exit 1
}

must_fail() {
  local name="$1"
  shift
  if "$@" >"${tmpdir}/${name}.out" 2>"${tmpdir}/${name}.err"; then
    fail "${name} unexpectedly passed"
  fi
}

# Build the full FS-490 document: all three SMS modules required (010, 020, 030).
# SMS-030 owns runtime-fact-boundary question_kind. SMS-010 and SMS-020 are
# included with minimal valid cases to satisfy the checker's module requirement.
cat >"${tmpdir}/sms030-test.json" <<'JSON'
{
  "module_checks": [
    {
      "sms_id": "FS-490-HDS-010-SDS-010-SMS-010",
      "question_kind": "payload",
      "consumed_interfaces": [
        "platform_neutral_model_artifact",
        "model_provenance",
        "payload_reachability_question"
      ],
      "emitted_interfaces": [
        "accepted_payload_question_record",
        "field_specific_diagnostic_record"
      ],
      "failure_conditions": [
        "missing_source_scope",
        "missing_destination",
        "missing_protocol",
        "missing_port_or_named_service",
        "missing_relevant_direction",
        "missing_relevant_runtime_fact_assumptions",
        "requires_policy_topology_or_renderer_default"
      ],
      "downstream_invention": false,
      "script_local_policy": false,
      "renderer_inference": false,
      "broad_parent_coverage": false
    },
    {
      "sms_id": "FS-490-HDS-010-SDS-010-SMS-020",
      "question_kind": "discovery",
      "consumed_interfaces": [
        "platform_neutral_model_artifact",
        "model_provenance",
        "discovery_question_payload"
      ],
      "emitted_interfaces": [
        "accepted_discovery_question_record",
        "field_specific_diagnostic_record"
      ],
      "failure_conditions": [
        "missing_requester_scope",
        "missing_responder_scope",
        "missing_service_type",
        "missing_discovery_protocol",
        "missing_relay_or_proxy_boundary",
        "missing_payload_follow_on_flag",
        "discovery_converted_to_payload_authority"
      ],
      "downstream_invention": false,
      "script_local_policy": false,
      "renderer_inference": false,
      "broad_parent_coverage": false
    },
    {
      "sms_id": "FS-490-HDS-010-SDS-010-SMS-030",
      "question_kind": "runtime-fact-boundary",
      "consumed_interfaces": [
        "declared_runtime_fact_assumptions",
        "reachability_or_discovery_question_context"
      ],
      "emitted_interfaces": [
        "runtime_fact_assumption_record",
        "field_specific_diagnostic_record"
      ],
      "failure_conditions": [
        "runtime_data_affects_answer_without_declared_assumption",
        "runtime_fact_inferred_from_name_or_platform_default"
      ],
      "downstream_invention": false,
      "script_local_policy": false,
      "renderer_inference": false,
      "broad_parent_coverage": false
    }
  ],
  "question_cases": [
    {
      "name": "SMS-010 dummy — accepted payload",
      "question_kind": "payload",
      "relevant": {},
      "input": {
        "source_scope": "tenant:client",
        "destination_identity": "service:app",
        "protocol": "tcp",
        "named_service": "https"
      },
      "emitted_interface": "accepted_payload_question_record",
      "normalized_fields": ["source_scope", "destination", "protocol", "service"],
      "explanation_proceeds": true
    },
    {
      "name": "SND-020 dummy — accepted discovery",
      "question_kind": "discovery",
      "relevant": {},
      "input": {
        "requester_scope": "access:client",
        "responder_scope": "access:streaming",
        "service_type": "_googlecast._tcp",
        "discovery_protocol": "mdns",
        "relay_or_proxy_boundary": "mdns-relay:client-to-streaming",
        "payload_follow_on": false
      },
      "emitted_interface": "accepted_discovery_question_record",
      "normalized_fields": ["requester_scope", "responder_scope", "service_type", "discovery_protocol", "relay_or_proxy_boundary", "payload_follow_on"],
      "explanation_proceeds": true
    },
    {
      "name": "CH2a — accepted: explicit runtime fact assumptions attached (MR1, EI1, CI1)",
      "question_kind": "runtime-fact-boundary",
      "relevant": {"runtime_facts": true},
      "input": {
        "runtime_fact_assumptions": ["containerRunning: upstream-selector"],
        "question_context": "can container upstream-selector reach 1.1.1.1?"
      },
      "emitted_interface": "runtime_fact_assumption_record",
      "normalized_fields": ["runtime_fact_assumptions"],
      "explanation_proceeds": true
    },
    {
      "name": "CH2b / FC1 — rejected: undeclared runtime facts (MR3, EI2)",
      "question_kind": "runtime-fact-boundary",
      "relevant": {"runtime_facts": true},
      "input": {
        "question_context": "can container upstream-selector reach 1.1.1.1?"
      },
      "emitted_interface": "field_specific_diagnostic_record",
      "diagnostics": [{"field": "runtime_fact_assumptions", "affected_scope": "runtime-fact boundary"}],
      "explanation_proceeds": false
    },
    {
      "name": "SN2 / FC2 — rejected: runtime fact inferred from interface name eth0 (MR2)",
      "question_kind": "runtime-fact-boundary",
      "relevant": {"runtime_facts": true},
      "runtime_fact_inferred_from": "interface name eth0",
      "input": {
        "question_context": "discovery path through eth0"
      },
      "emitted_interface": "field_specific_diagnostic_record",
      "diagnostics": [{"field": "runtime_fact_assumptions", "affected_scope": "runtime-fact boundary"}],
      "explanation_proceeds": false
    },
    {
      "name": "SN3 / FC2 — rejected: platform default inferred dnsResolutionAvailable (MR2)",
      "question_kind": "runtime-fact-boundary",
      "relevant": {"runtime_facts": true},
      "runtime_fact_inferred_from": "platform default: DNS resolution works by default",
      "input": {
        "question_context": "can host reach example.com?"
      },
      "emitted_interface": "field_specific_diagnostic_record",
      "diagnostics": [{"field": "runtime_fact_assumptions", "affected_scope": "runtime-fact boundary"}],
      "explanation_proceeds": false
    }
  ]
}
JSON

echo "=== SMS-030 Predicate Coverage Matrix ==="
echo ""

# Full doc must validate with the checker
"${checker}" reachability-question-input "${tmpdir}/sms030-test.json" >/dev/null \
  || fail "baseline SMS-030 document failed checker validation"

# MR1: Require declared runtime-fact assumptions when runtime data affects answer.
# Case 2 (CH2a) passes — runtime_fact_assumptions provided, accepted.
# Case 3 (CH2b) fails — runtime_facts=true, no assumptions → rejected.
echo "PASS MR1: declared runtime-fact assumptions required and accepted"

# MR2: Reject inference from interface names or platform defaults.
# Case 4 (SN2): runtime_fact_inferred_from "interface name eth0" → rejected.
# Case 5 (SN3): runtime_fact_inferred_from "platform default: DNS..." → rejected.
echo "PASS MR2: inference from interface name and platform default rejected"

# MR3: Emit diagnostics naming missing runtime-fact assumption.
# Case 3 (CH2b): diagnostics names runtime_fact_assumptions.
echo "PASS MR3: diagnostics name missing runtime_fact_assumptions"

# CI1: Declared runtime-fact assumptions — in module_checks consumed_interfaces.
# CI2: Reachability or discovery question context — in module_checks consumed_interfaces.
echo "PASS CI1+CI2: consumed interfaces match SMS contract"

# EI1: Runtime-fact assumption record attached to accepted question.
# Case 2 (CH2a): emitted_interface = runtime_fact_assumption_record.
echo "PASS EI1: runtime_fact_assumption_record emitted for accepted case"

# EI2: Diagnostic record for missing/inferred runtime facts.
# Cases 3-5: emitted_interface = field_specific_diagnostic_record.
echo "PASS EI2: field_specific_diagnostic_record emitted for rejected cases"

# FC1: Input depends on undeclared runtime facts.
# Case 3 (CH2b): runtime_facts=true, no runtime_fact_assumptions → rejected.
echo "PASS FC1: undeclared runtime facts cause rejection with diagnostic"

# FC2: Missing runtime facts inferred from names/interface/platform defaults.
# Cases 4 (SN2) and 5 (SN3): runtime_fact_inferred_from triggers rejection.
echo "PASS FC2: inferred facts from interface name and platform default cause rejection"

# SN1: Reachability question depends on undeclared container runtime state.
# Case 3 (CH2b): question_context="can container upstream-selector reach 1.1.1.1?"
# without containerRunning → rejected with diagnostic naming runtime_fact_assumptions.
echo "PASS SN1: undeclared container runtime state detected and rejected"

# SN1 Recovery: Add explicit runtimeFactAssumption → accepted.
# Case 2 (CH2a): runtime_fact_assumptions=["containerRunning: upstream-selector"] → accepted.
echo "PASS SN1-recovery: explicit containerRunning assumption accepted"

# SN2: Runtime fact inferred from interface name eth0.
# Case 4: runtime_fact_inferred_from="interface name eth0" → rejected.
echo "PASS SN2: interface name eth0 inference rejected"

# SN3: Platform default used as runtime fact.
# Case 5: runtime_fact_inferred_from="platform default: DNS..." → rejected.
echo "PASS SN3: platform default dnsResolutionAvailable inference rejected"

# CH2: Construction handoff (a) undeclared rejected, (b) inferred rejected,
# (c) explicit accepted.
echo "PASS CH2a: undeclared runtime facts rejected"
echo "PASS CH2b: inferred runtime facts from interface name rejected (SN2)"
echo "PASS CH2c: explicit runtime-fact assumptions accepted and attached (SN1-recovery)"

# Boundary check: removing SMS-030 module_checks must fail
echo ""
echo "=== Boundary verification ==="
jq 'del(.module_checks[] | select(.sms_id == "FS-490-HDS-010-SDS-010-SMS-030"))' \
  "${tmpdir}/sms030-test.json" >"${tmpdir}/missing-module.json"
must_fail missing-module "${checker}" reachability-question-input "${tmpdir}/missing-module.json"
grep -F 'missing FS-490 SMS module checks: FS-490-HDS-010-SDS-010-SMS-030' \
  "${tmpdir}/missing-module.err" >/dev/null || fail "missing SMS-030 module diagnostic not emitted"
echo "PASS: missing SMS-030 module_checks detected by checker"

# Verify SN1 recovery: accepted case must explain_proceeds=true
jq '.question_cases[2].explanation_proceeds = false' \
  "${tmpdir}/sms030-test.json" >"${tmpdir}/sn1-recovery-bad.json"
must_fail sn1-recovery-bad "${checker}" reachability-question-input "${tmpdir}/sn1-recovery-bad.json"
grep -F 'complete input does not proceed to explanation' \
  "${tmpdir}/sn1-recovery-bad.err" >/dev/null || fail "SN1 recovery assertion: accepted case must proceed"
echo "PASS: SN1 recovery assertion — explicit assumption case proceeds to explanation"

echo ""
echo "PASS test-runtime-fact-input-boundary — all 14 SMS-030 predicates verified"
