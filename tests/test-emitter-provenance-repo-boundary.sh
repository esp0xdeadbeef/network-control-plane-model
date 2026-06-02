#!/usr/bin/env bash
set -euo pipefail
# GAMP-ID: SMT-CPM-PROVENANCE-001
# GAMP-SCOPE: software-module-test

repo_root="$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)"
foreign_cwd="${NETWORK_FOREIGN_CWD:-/home/deadbeef/github/network-codex-agent}"

fail() {
  echo "$1" >&2
  exit 1
}

[[ -d "${foreign_cwd}" ]] || foreign_cwd="/tmp"

archive_json="$(mktemp)"
tmp_dir="$(mktemp -d)"
trap 'rm -f "${archive_json}"; rm -rf "${tmp_dir}"' EXIT

nix flake archive --json "path:${repo_root}" > "${archive_json}"
labs_root="$(jq -er '.inputs["network-labs"].path' "${archive_json}")"
intent="${labs_root}/examples/single-wan/intent.nix"
inventory="${labs_root}/examples/single-wan/inventory-nixos.nix"
[[ -f "${intent}" ]] || fail "missing intent: ${intent}"
[[ -f "${inventory}" ]] || fail "missing inventory: ${inventory}"

own_rev="$(git -C "${repo_root}" rev-parse HEAD)"
foreign_rev="$(git -C "${foreign_cwd}" rev-parse HEAD 2>/dev/null || true)"

(
  cd "${foreign_cwd}"
  nix run --no-warn-dirty --no-write-lock-file "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent}" "${inventory}" "${tmp_dir}/foreign.json" \
    > "${tmp_dir}/foreign.stdout"
)

jq -e --arg foreign "${foreign_rev}" '
  .control_plane_model.meta.networkControlPlaneModel.name == "network-control-plane-model"
  and (.control_plane_model.meta.networkControlPlaneModel.sourceNarHash // "") != ""
  and (
    ($foreign == "")
    or (.control_plane_model.meta.networkControlPlaneModel.gitRev != $foreign)
  )
' "${tmp_dir}/foreign.json" >/dev/null \
  || fail "CPM provenance used the foreign caller repository"

(
  cd "${repo_root}"
  nix run --no-warn-dirty --no-write-lock-file "path:${repo_root}#compile-and-build-control-plane-model" -- \
    "${intent}" "${inventory}" "${tmp_dir}/own.json" \
    > "${tmp_dir}/own.stdout"
)

jq -e --arg own "${own_rev}" '
  .control_plane_model.meta.networkControlPlaneModel.name == "network-control-plane-model"
  and .control_plane_model.meta.networkControlPlaneModel.gitRev == $own
  and (.control_plane_model.meta.networkControlPlaneModel.gitDirty | type == "boolean")
' "${tmp_dir}/own.json" >/dev/null \
  || fail "CPM provenance did not use the emitter repository"

echo "PASS emitter-provenance-repo-boundary"
