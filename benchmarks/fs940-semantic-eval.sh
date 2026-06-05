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
timing_method="date_ms_min_of_${sample_count}"

repo_revision="$(git -C "${repo_root}" rev-parse HEAD 2>/dev/null || echo unknown)"
repo_dirty=false
if ! git -C "${repo_root}" diff --quiet >/dev/null 2>&1 || ! git -C "${repo_root}" diff --cached --quiet >/dev/null 2>&1; then
  repo_dirty=true
fi
locked_revisions="$(jq -r '[.nodes | to_entries[] | select(.value.locked.rev?) | "\(.key)=\(.value.locked.rev)"] | join(",")' "${repo_root}/flake.lock")"
host_class="$(uname -m)-$(uname -s | tr '[:upper:]' '[:lower:]')"
excluded_runtime_stages="nix-build,container-image-build,vm-deployment,containerlab-deployment,boot,live-packet-validation,provider-calls,cache-misses"

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
    s-router-overlay-dns-lane-policy
    tri-site-dual-wan-overlay-integration-static
  )
fi

failed=0

for example in "${examples[@]}"; do
  intent="${labs_root}/examples/${example}/intent.nix"
  inventory="${labs_root}/examples/${example}/inventory-nixos.nix"
  if [[ ! -f "${intent}" || ! -f "${inventory}" ]]; then
    echo "FAIL fs940-semantic-eval ${example}: missing intent or inventory" >&2
    failed=1
    continue
  fi

  nix run --no-warn-dirty --no-write-lock-file "path:${repo_root}#compile-and-build-control-plane-model" -- "${intent}" "${inventory}" "${forwarding_json}.cpm-warmup" >/dev/null
  nix run --no-warn-dirty --no-write-lock-file "path:$(jq -er '.inputs["network-forwarding-model"].path' "${archive_json}")#compile-and-build-forwarding-model" -- "${intent}" >"${forwarding_json}"

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

  env FORWARDING_JSON="${forwarding_json}" INVENTORY="${inventory}" \
    nix eval \
      --extra-experimental-features 'nix-command flakes' \
      --impure \
      --json \
      "path:${repo_root}#libBySystem.x86_64-linux" \
      --apply "${eval_expr}" >/dev/null

  summary=""
  elapsed_ms=""
  sample_failed=0
  for sample_idx in $(seq 1 "${sample_count}"); do
    start_ms="$(date +%s%3N)"
    if ! sample_summary="$(
      env FORWARDING_JSON="${forwarding_json}" INVENTORY="${inventory}" \
        timeout "$((threshold_ms / 1000 + 20))" \
        nix eval \
          --extra-experimental-features 'nix-command flakes' \
          --impure \
          --json \
          "path:${repo_root}#libBySystem.x86_64-linux" \
          --apply "${eval_expr}"
    )"; then
      end_ms="$(date +%s%3N)"
      sample_elapsed_ms=$((end_ms - start_ms))
      echo "BENCH fs940 stage=control-plane-model example=${example} status=FAIL elapsed_ms=${sample_elapsed_ms} threshold_ms=${threshold_ms} repo_revision=${repo_revision} repo_dirty=${repo_dirty} locked_revisions=${locked_revisions} timing_method=${timing_method} host_class=${host_class} cache_state=warm-required command=nix-eval-libBySystem.get_CPM upstream_cardinality=unknown downstream_cardinality=unknown excluded_runtime_stages=${excluded_runtime_stages}" >&2
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
  if [ "${elapsed_ms}" -gt "${threshold_ms}" ]; then
    status=FAIL
    failed=1
  fi

  downstream_cardinality="$(jq -r '.downstream | to_entries | map("\(.key):\(.value)") | join(",")' <<<"${summary}")"

  echo "BENCH fs940 stage=control-plane-model example=${example} status=${status} elapsed_ms=${elapsed_ms} threshold_ms=${threshold_ms} repo_revision=${repo_revision} repo_dirty=${repo_dirty} locked_revisions=${locked_revisions} timing_method=${timing_method} host_class=${host_class} cache_state=warm-required command=nix-eval-libBySystem.get_CPM upstream_cardinality=${upstream_cardinality} downstream_cardinality=${downstream_cardinality} excluded_runtime_stages=${excluded_runtime_stages}"
done

exit "${failed}"
