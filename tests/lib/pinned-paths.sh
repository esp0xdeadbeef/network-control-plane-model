#!/usr/bin/env bash
# tests/lib/pinned-paths.sh — Resolve pinned flake input paths for CPM tests.
# Sources the flake to find canonical store paths for network-labs.
# Results are cached per-session. Set NETWORK_LABS_PATH env var to override.
set -euo pipefail

_pinned_cache_dir="${TMPDIR:-/var/tmp}/cpm-pinned-paths-$$"
mkdir -p "${_pinned_cache_dir}"

_pinned_network_labs=""

_resolve_network_labs() {
  if [[ -n "${_pinned_network_labs}" ]]; then
    echo "${_pinned_network_labs}"
    return
  fi
  if [[ -n "${NETWORK_LABS_PATH:-}" ]]; then
    _pinned_network_labs="${NETWORK_LABS_PATH}"
    echo "${_pinned_network_labs}"
    return
  fi
  local cache_file="${_pinned_cache_dir}/network-labs-path"
  if [[ -f "${cache_file}" ]]; then
    _pinned_network_labs="$(cat "${cache_file}")"
    echo "${_pinned_network_labs}"
    return
  fi
  local resolved
  if resolved="$(nix eval --no-write-lock-file --impure --raw --expr '
    let flake = builtins.getFlake (toString ./.);
    in flake.inputs.network-labs.outPath or ""
  ' 2>/dev/null)"; then
    if [[ -n "${resolved}" ]]; then
      _pinned_network_labs="${resolved}"
      echo "${resolved}" > "${cache_file}"
      echo "${_pinned_network_labs}"
      return
    fi
  fi
  echo "ERROR: cannot resolve network-labs flake input. Set NETWORK_LABS_PATH." >&2
  exit 1
}

pinned_network_labs() { _resolve_network_labs; }
pinned_hat_dir()  { echo "$(_resolve_network_labs)/GAMP/HAT/emulated-isp-residential-testnet"; }
pinned_sat_dir()  { echo "$(_resolve_network_labs)/GAMP/SAT"; }

# A pinned network-labs example directory.
#
# `network-*` repositories may not read fixtures from the `nixos` consumer
# repository; the fixture home for these repositories is `network-labs`, which is
# a pinned flake input. Cases that used to compile a production testing model
# call this instead and get the same store path CI resolves from the lock.
pinned_lab_example() {
  local example="$1"
  local dir
  dir="$(_resolve_network_labs)/examples/${example}"
  if [[ ! -f "${dir}/intent.nix" ]]; then
    echo "ERROR: network-labs example '${example}' has no intent.nix at ${dir}" >&2
    exit 1
  fi
  echo "${dir}"
}
