#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

threshold_ms="${CPM_BENCH_THRESHOLD_MS:-3000}"
if ! [[ "${threshold_ms}" =~ ^[0-9]+$ ]] || [ "${threshold_ms}" -lt 1 ]; then
  echo "FAIL fs940-semantic-eval: CPM_BENCH_THRESHOLD_MS must be a positive integer" >&2
  exit 1
fi
sample_count="${CPM_BENCH_SAMPLES:-2}"
if ! [[ "${sample_count}" =~ ^[0-9]+$ ]] || [ "${sample_count}" -lt 1 ]; then
  echo "FAIL fs940-semantic-eval: CPM_BENCH_SAMPLES must be a positive integer" >&2
  exit 1
fi
# timing_method=date_ms is the stable benchmark timing label checked by the
# contract test; the runtime summary still records the sample aggregation shape.
timing_method="date_ms_min_of_${sample_count}"

repo_revision="$(git -C "${repo_root}" rev-parse HEAD 2>/dev/null || echo unknown)"
repo_dirty=false
if ! git -C "${repo_root}" diff --quiet >/dev/null 2>&1 || ! git -C "${repo_root}" diff --cached --quiet >/dev/null 2>&1; then
  repo_dirty=true
fi
locked_revisions="$(jq -r '[.nodes | to_entries[] | select(.value.locked.rev?) | "\(.key)=\(.value.locked.rev)"] | join(",")' "${repo_root}/flake.lock")"
host_class="$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]')"
excluded_runtime_stages="nix-build,container-image-build,vm-deployment,containerlab-deployment,boot,live-packet-validation,provider-calls,cache-misses"

sanitize_bench_value() {
  tr '\n' ' ' |
    sed -E 's/[[:space:]]+/_/g; s/[^A-Za-z0-9_.:=,\/-]/_/g; s/_+$//' |
    cut -c1-160
}

stderr_summary_for() {
  local stderr_file="$1"
  if [[ -s "${stderr_file}" ]]; then
    sanitize_bench_value <"${stderr_file}"
  else
    printf 'none'
  fi
}

emit_bench_record() {
  local status="$1"
  local example="$2"
  local elapsed_ms="$3"
  local command_label="$4"
  local exit_code="$5"
  local stderr_summary="$6"
  local upstream_cardinality="$7"
  local downstream_cardinality="$8"
  local threshold_status="$9"
  local diagnostic="${10}"

  echo "BENCH fs940 stage=control-plane-model example=${example} status=${status} elapsed_ms=${elapsed_ms} threshold_ms=${threshold_ms} threshold_status=${threshold_status} gate=diagnostic repo_revision=${repo_revision} repo_dirty=${repo_dirty} locked_revisions=${locked_revisions} timing_method=${timing_method} host_class=${host_class} cache_state=warm-required command=${command_label} exit_code=${exit_code} stderr_summary=${stderr_summary} upstream_cardinality=${upstream_cardinality} downstream_cardinality=${downstream_cardinality} excluded_runtime_stages=${excluded_runtime_stages} diagnostic=${diagnostic}"
}

archive_json="$(mktemp)"
forwarding_json="$(mktemp --suffix=.json)"
trap 'rm -f "${archive_json}" "${forwarding_json}"' EXIT
nix flake archive --json "path:${repo_root}" >"${archive_json}"
labs_root="$(jq -er '.inputs["network-labs"].path' "${archive_json}")"

if [[ -n "${CPM_BENCH_EXAMPLES:-}" ]]; then
  # Intentionally split on shell whitespace so focused callers can pass one or
  # more example names without changing the benchmark script.
  # shellcheck disable=SC2206
  examples=( ${CPM_BENCH_EXAMPLES} )
else
  examples=(
    s-router-public-overlay-service
    single-wan
  )
fi

failed=0

for example in "${examples[@]}"; do
  intent="${labs_root}/examples/${example}/intent.nix"
  inventory="${labs_root}/examples/${example}/inventory-nixos.nix"
  if [[ ! -f "${intent}" || ! -f "${inventory}" ]]; then
    emit_bench_record \
      "FAIL" \
      "${example}" \
      0 \
      "input-discovery" \
      66 \
      "missing_intent_or_inventory" \
      "unknown" \
      "unknown" \
      "not-evaluated" \
      "diagnostic.stage-benchmark-input-missing" >&2
    failed=1
    continue
  fi

  warmup_stderr="$(mktemp)"
  nfm_stderr="$(mktemp)"
  preflight_stderr="$(mktemp)"
  sample_stderr="$(mktemp)"
  trap 'rm -f "${archive_json}" "${forwarding_json}" "${warmup_stderr:-}" "${nfm_stderr:-}" "${preflight_stderr:-}" "${sample_stderr:-}"' EXIT

  start_ms="$(date +%s%3N)"
  set +e
  nix run --no-warn-dirty --no-write-lock-file "path:${repo_root}#compile-and-build-control-plane-model" -- "${intent}" "${inventory}" "${forwarding_json}.cpm-warmup" >/dev/null 2>"${warmup_stderr}"
  command_status=$?
  set -e
  if [[ "${command_status}" -ne 0 ]]; then
    end_ms="$(date +%s%3N)"
    emit_bench_record \
      "FAIL" \
      "${example}" \
      "$((end_ms - start_ms))" \
      "nix-run-compile-and-build-control-plane-model-warmup" \
      "${command_status}" \
      "$(stderr_summary_for "${warmup_stderr}")" \
      "unknown" \
      "unknown" \
      "not-evaluated" \
      "diagnostic.stage-benchmark-command-failure-recorded" >&2
    failed=1
    continue
  fi

  start_ms="$(date +%s%3N)"
  set +e
  nix run --no-warn-dirty --no-write-lock-file "path:$(jq -er '.inputs["network-forwarding-model"].path' "${archive_json}")#compile-and-build-forwarding-model" -- "${intent}" >"${forwarding_json}" 2>"${nfm_stderr}"
  command_status=$?
  set -e
  if [[ "${command_status}" -ne 0 ]]; then
    end_ms="$(date +%s%3N)"
    emit_bench_record \
      "FAIL" \
      "${example}" \
      "$((end_ms - start_ms))" \
      "nix-run-compile-and-build-forwarding-model" \
      "${command_status}" \
      "$(stderr_summary_for "${nfm_stderr}")" \
      "unknown" \
      "unknown" \
      "not-evaluated" \
      "diagnostic.stage-benchmark-command-failure-recorded" >&2
    failed=1
    continue
  fi

  upstream_cardinality="$(
    jq -r '
      [(.enterprise // {})[] | (.site // {})[]] as $sites
      | {
          sites: ($sites | length),
          nodes: ([ $sites[] | (.nodes // {}) | keys[] ] | length),
          interfaces: ([ $sites[] | (.nodes // {})[] | (.interfaces // {}) | keys[] ] | length)
        }
      | to_entries
      | map("\(.key):\(.value)")
      | join(",")
    ' "${forwarding_json}"
  )"

  eval_expr="$(cat <<'NIX'
          cpmLib:
          let
            forwarding = builtins.fromJSON (builtins.readFile (builtins.getEnv "FORWARDING_JSON"));
            inventoryRaw = import (builtins.getEnv "INVENTORY");
            inventory = if builtins.isFunction inventoryRaw then inventoryRaw { } else inventoryRaw;
            cpm = cpmLib.get_CPM {
              input = forwarding;
              inherit inventory;
            };
            cpmSites =
              builtins.concatMap
                (enterpriseName:
                  map
                    (siteName: builtins.getAttr siteName (builtins.getAttr enterpriseName cpm.data))
                    (builtins.attrNames (builtins.getAttr enterpriseName cpm.data)))
                (builtins.attrNames cpm.data);
          in
          {
            downstream = {
              sites = builtins.length cpmSites;
              runtimeTargets = builtins.foldl' (acc: site: acc + builtins.length (builtins.attrNames (site.runtimeTargets or { }))) 0 cpmSites;
              interfaces = builtins.foldl' (acc: site: acc + builtins.foldl' (racc: rt: racc + builtins.length (builtins.attrNames (rt.interfaces or { }))) 0 (builtins.attrValues (site.runtimeTargets or { }))) 0 cpmSites;
            };
          }
NIX
)"

  set +e
  env FORWARDING_JSON="${forwarding_json}" INVENTORY="${inventory}" \
    nix eval \
      --extra-experimental-features 'nix-command flakes' \
      --impure \
      --json \
      "path:${repo_root}#libBySystem.x86_64-linux" \
      --apply "${eval_expr}" >/dev/null 2>"${preflight_stderr}"
  command_status=$?
  set -e
  if [[ "${command_status}" -ne 0 ]]; then
    emit_bench_record \
      "FAIL" \
      "${example}" \
      0 \
      "nix-eval-libBySystem.get_CPM-preflight" \
      "${command_status}" \
      "$(stderr_summary_for "${preflight_stderr}")" \
      "${upstream_cardinality}" \
      "unknown" \
      "not-evaluated" \
      "diagnostic.stage-benchmark-command-failure-recorded" >&2
    failed=1
    continue
  fi

  summary=""
  elapsed_ms=""
  sample_failed=0
  for sample_idx in $(seq 1 "${sample_count}"); do
    start_ms="$(date +%s%3N)"
    set +e
    sample_summary="$(
      env FORWARDING_JSON="${forwarding_json}" INVENTORY="${inventory}" \
        timeout "$((threshold_ms / 1000 + 20))" \
        nix eval \
          --extra-experimental-features 'nix-command flakes' \
          --impure \
          --json \
          "path:${repo_root}#libBySystem.x86_64-linux" \
          --apply "${eval_expr}" 2>"${sample_stderr}"
    )"
    command_status=$?
    set -e
    if [[ "${command_status}" -ne 0 ]]; then
      end_ms="$(date +%s%3N)"
      sample_elapsed_ms=$((end_ms - start_ms))
      emit_bench_record \
        "FAIL" \
        "${example}" \
        "${sample_elapsed_ms}" \
        "nix-eval-libBySystem.get_CPM" \
        "${command_status}" \
        "$(stderr_summary_for "${sample_stderr}")" \
        "${upstream_cardinality}" \
        "unknown" \
        "not-evaluated" \
        "diagnostic.stage-benchmark-command-failure-recorded" >&2
      failed=1
      sample_failed=1
      break
    fi
    end_ms="$(date +%s%3N)"
    sample_elapsed_ms=$((end_ms - start_ms))
    if [[ -z "${elapsed_ms}" || "${sample_elapsed_ms}" -lt "${elapsed_ms}" ]]; then
      elapsed_ms="${sample_elapsed_ms}"
      summary="${sample_summary}"
    fi
  done
  if [[ "${sample_failed}" -ne 0 ]]; then
    continue
  fi

  status=PASS
  threshold_status=PASS
  if [ "${elapsed_ms}" -gt "${threshold_ms}" ]; then
    threshold_status=OVER_THRESHOLD
  fi

  downstream_cardinality="$(jq -r '.downstream | to_entries | map("\(.key):\(.value)") | join(",")' <<<"${summary}")"

  emit_bench_record \
    "${status}" \
    "${example}" \
    "${elapsed_ms}" \
    "nix-eval-libBySystem.get_CPM" \
    0 \
    "none" \
    "${upstream_cardinality}" \
    "${downstream_cardinality}" \
    "${threshold_status}" \
    "none"
done

exit "${failed}"
