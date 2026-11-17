#!/usr/bin/env bash
# GAMP-ID: FS-255-HDS-010-SDS-010-SMS-010
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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

hat_dir="$(pinned_hat_dir)"
intent_path="${hat_dir}/intent.nix"
nixos_output="${tmp_dir}/nixos-cpm.json"
clab_output="${tmp_dir}/clab-cpm.json"

build_cpm() {
  local inventory="$1"
  local output="$2"

  nix run --no-write-lock-file \
    --no-write-lock-file \
    --extra-experimental-features 'nix-command flakes' \
    "${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent_path}" \
    "${inventory}" \
    "${output}" >/dev/null
}

validate_core_cardinality() {
  local input="$1"
  local label="${2:-core host-facing cardinality}"
  local quiet="${3:-0}"
  local result
  if ! result="$(jq -e '
    def core_targets:
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[] as $target
        | select(($target.value.role // "") == "core")
        | {
            target: $target.key,
            role: $target.value.role,
            egressIntent: ($target.value.egressIntent // { }),
            interfaces: (($target.value.effectiveRuntimeRealization.interfaces // {}) | to_entries)
          }
      ];

    # FS-255: a core models exactly two host attachments -- the ingress-facing
    # selector surface and one egress-facing reachability surface. An uplink
    # that only carries a modeled provider tunnel (providerOverlay) is the
    # adapter of that tunnel, so it is not the egress attachment; the tenant
    # carriage port is. Both must be inventory-backed: a surface synthesized
    # from intent (sourceClass runtime-facts) or from a host adapter
    # (core-egress) is not a surface, and an egress surface may not share the
    # bridge of the ingress p2p.
    def is_host_attachment($iface):
      ($iface.value.hostFacing == true)
      and ($iface.value.virtualAdapter != true)
      and (($iface.value.providerOverlay // null) == null);

    def host_attachments($target): $target.interfaces | map(select(is_host_attachment(.)));

    def owns_local_egress($target):
      (($target.egressIntent.exit // false) == true) or (($target.egressIntent.eligible // false) == true);

    def inventory_backed($iface):
      (($iface.value.binderSourceAudit.sourceClass // "") == "public-inventory")
      or (($iface.value.explicit.explicitWan // false) == true);

    def valid_attachment($iface):
      (($iface.value.direction == "ingress" and $iface.value.adapterClass == "p2p-realization")
       or
       ($iface.value.direction == "egress"
        and (
          ($iface.value.sourceKind // "") == "wan"
          or ($iface.value.sourceKind // "") == "pppoe-handoff"
          or ($iface.value.sourceKind // "") == "tenant"
        )))
      and inventory_backed($iface);

    core_targets as $targets
    | [
        $targets[]
        | host_attachments(.) as $host
        | {
            target,
            ownsLocalEgress: owns_local_egress(.),
            hostFacingCount: ($host | length),
            ingressCount: ($host | map(select(.value.direction == "ingress")) | length),
            egressCount: ($host | map(select(.value.direction == "egress")) | length),
            invalidHostFacing: ($host | map(select(valid_attachment(.) | not)) | map(.key)),
            syntheticSurfaces: (
              .interfaces
              | map(select((.value.sourceKind // "") == "core-egress") | .key)
            ),
            egressOnIngressBridge: (
              [
                $host[]
                | select(.value.direction == "egress")
                | (.value.attach.bridge // "")
              ] as $egressBridges
              | [ $host[] | select(.value.direction == "ingress") | (.value.attach.bridge // "") ] as $ingressBridges
              | [ $egressBridges[] | select(. as $b | ($ingressBridges | index($b)) != null) ]
            )
          }
        | select(
            # Exactly one selector ingress for every core. The egress side is
            # one REACHABILITY leg: a core that terminates a local exit needs at
            # least one (its WAN/provider handoff; a tenant LAN port next to it
            # is an attachment, not the reachability leg), while a core whose
            # exit is a selected remote tenant context needs exactly one -- the
            # `underlayAccess` carriage attachment (FS-255, FS-260, FS-460/470).
            # A single-cable core is never exempt.
            .ingressCount != 1
            or (if .ownsLocalEgress then .egressCount < 1 else .egressCount != 1 end)
            or .hostFacingCount < 2
            or (.invalidHostFacing | length) != 0
            or (.syntheticSurfaces | length) != 0
            or (.egressOnIngressBridge | length) != 0
          )
      ] as $violations
    | {
        trace: "FS-255-HDS-010-SDS-010-SMS-010",
        coreTargetCount: ($targets | length),
        violations: $violations
      }
    | select(.coreTargetCount > 0 and (.violations | length) == 0)
  ' "${input}")"; then
    if [[ "${quiet}" != "1" ]]; then
      echo "FAIL FS-255-HDS-010-SDS-010-SMS-010 ${label}: core host-facing cardinality violated (every core needs exactly one ingress-facing and one egress-facing host attachment)" >&2
      jq '
      def core_targets: [ .control_plane_model.data | to_entries[] as $e | $e.value | to_entries[] as $s | $s.value.runtimeTargets | to_entries[] | select((.value.role // "") == "core") | { target: $s.key, egressIntent: (.value.egressIntent // { }), interfaces: ((.value.effectiveRuntimeRealization.interfaces // {}) | to_entries) } ];
      def is_host_attachment($i): ($i.value.hostFacing == true) and ($i.value.virtualAdapter != true) and (($i.value.providerOverlay // null) == null);
      def host_attachments($t): $t.interfaces | map(select(is_host_attachment(.)));
      def owns_local_egress($t): (($t.egressIntent.exit // false) == true) or (($t.egressIntent.eligible // false) == true);
      [ core_targets[] | host_attachments(.) as $h | { target, ownsLocalEgress: owns_local_egress(.), n: ($h|length), ingress: ($h|map(select(.value.direction=="ingress"))|length), egress: ($h|map(select(.value.direction=="egress"))|length), surfaces: ($h|map(.key)) } | select(
            .ingress != 1 or (if .ownsLocalEgress then .egress < 1 else .egress != 1 end) or .n < 2
          ) ]
    ' "${input}" >&2 || true
    fi
    return 1
  fi
}

mutate_first_core() {
  local input="$1"
  local output="$2"
  local mutation="$3"

  jq --arg mutation "${mutation}" '
    def is_host_attachment($i):
      ($i.value.hostFacing == true)
      and ($i.value.virtualAdapter != true)
      and (($i.value.providerOverlay // null) == null);
    def first_core_ids:
      # A core that carries an inventory-backed host egress attachment: the
      # mutations inject/remove/re-provenance that attachment.
      [
        .control_plane_model.data
        | to_entries[] as $enterprise
        | $enterprise.value
        | to_entries[] as $site
        | $site.value.runtimeTargets
        | to_entries[]
        | select((.value.role // "") == "core")
        | select(any(.value.effectiveRuntimeRealization.interfaces // {} | to_entries[]?;
            is_host_attachment(.)
            and (.value.direction == "egress")
            and ((.value.binderSourceAudit.sourceClass // "") == "public-inventory")))
        | [$enterprise.key, $site.key, .key]
      ][0];

    first_core_ids as $ids
    | ["control_plane_model", "data", $ids[0], $ids[1], "runtimeTargets", $ids[2], "effectiveRuntimeRealization", "interfaces"] as $p
    | (getpath($p) | to_entries | map(select(is_host_attachment(.) and .value.direction == "egress")) | .[0].key) as $egress
    | (getpath($p) | to_entries | map(select(is_host_attachment(.) and .value.direction == "ingress")) | .[0]) as $ingress
    | if $mutation == "fanout" then
        setpath($p + ["fs255-extra-p2p-fanout"]; {
          sourceKind: "p2p",
          adapterClass: "p2p-realization",
          direction: "ingress",
          hostFacing: true,
          virtualAdapter: false,
          exclusionReason: "FS-255-HDS-010-SDS-010-SMS-010 seeded fanout"
        })
      elif $mutation == "renderer" then
        setpath($p + ["eth-renderer-convenience"]; {
          sourceKind: "renderer-convenience",
          adapterClass: "runtime-name-heuristic",
          direction: "egress",
          hostFacing: true,
          virtualAdapter: false,
          runtimeIfName: "eth99",
          exclusionReason: "FS-255-HDS-010-SDS-010-SMS-010 seeded renderer convenience"
        })
      elif $mutation == "missing-egress" then
        delpaths([$p + [$egress]])
      elif $mutation == "synthetic-egress" then
        # The removed synthesis: a host adapter copied from the ingress p2p,
        # counted as the egress of the core. No host has this surface.
        setpath($p + ["core-uplink-egress"];
          ($ingress.value
           + {
             sourceKind: "core-egress",
             adapterClass: "core-role-egress",
             direction: "egress",
             hostFacing: true,
             virtualAdapter: false,
             binderSourceAudit: (($ingress.value.binderSourceAudit // { }) + { sourceClass: "runtime-facts" }),
             exclusionReason: "FS-255-HDS-010-SDS-010-SMS-010 seeded synthetic egress"
           }))
      elif $mutation == "intent-only-carriage" then
        # A carriage surface claimed from intent with no inventory port behind it.
        setpath($p + [$egress, "binderSourceAudit", "sourceClass"]; "runtime-facts")
      elif $mutation == "bridge-collision" then
        # A fabricated carriage surface attached to the ingress p2p bridge.
        setpath($p + [$egress, "attach", "bridge"]; ($ingress.value.attach.bridge // ""))
      else
        .
      end
  ' "${input}" > "${output}"
}

assert_rejects() {
  local input="$1"
  local label="$2"

  if validate_core_cardinality "${input}" "seeded-${label}" 1; then
    echo "FAIL FS-255-HDS-010-SDS-010-SMS-010 ${label}: seeded violation was accepted" >&2
    exit 1
  fi
  echo "PASS FS-255-HDS-010-SDS-010-SMS-010 ${label}: seeded violation rejected"
}

build_cpm "${hat_dir}/inventory-nixos.nix" "${nixos_output}"
build_cpm "${hat_dir}/inventory-clab.nix" "${clab_output}"

validate_core_cardinality "${nixos_output}" "baseline nixos"
validate_core_cardinality "${clab_output}" "baseline clab"

for output in "${nixos_output}" "${clab_output}"; do
  fanout="${tmp_dir}/$(basename "${output}").fanout.json"
  missing="${tmp_dir}/$(basename "${output}").missing-egress.json"
  renderer="${tmp_dir}/$(basename "${output}").renderer.json"
  synthetic="${tmp_dir}/$(basename "${output}").synthetic-egress.json"
  intentonly="${tmp_dir}/$(basename "${output}").intent-only-carriage.json"
  bridge="${tmp_dir}/$(basename "${output}").bridge-collision.json"

  mutate_first_core "${output}" "${fanout}" "fanout"
  mutate_first_core "${output}" "${missing}" "missing-egress"
  mutate_first_core "${output}" "${renderer}" "renderer"
  mutate_first_core "${output}" "${synthetic}" "synthetic-egress"
  mutate_first_core "${output}" "${intentonly}" "intent-only-carriage"
  mutate_first_core "${output}" "${bridge}" "bridge-collision"

  assert_rejects "${fanout}" "fanout-injection"
  assert_rejects "${missing}" "missing-egress"
  assert_rejects "${renderer}" "renderer-convenience-injection"
  assert_rejects "${synthetic}" "synthetic-egress-injection"
  assert_rejects "${intentonly}" "intent-only-carriage-injection"
  assert_rejects "${bridge}" "bridge-collision-injection"

  validate_core_cardinality "${output}"
done

echo "PASS FS-255-HDS-010-SDS-010-SMS-010 core host-facing cardinality"
