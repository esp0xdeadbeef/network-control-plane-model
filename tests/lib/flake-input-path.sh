#!/usr/bin/env bash
# Resolve a flake input to a path WITHOUT touching the network.
#
# `nix flake archive --json "path:$root"` copies every input into the store, and for a
# `github:owner/repo/<rev>` input that means downloading archive/<rev>.tar.gz. In CI the
# store is closed and the network namespace is up by the time tests run, so the fetch
# fails and the case dies with something unrelated to what it tests:
#
#   unpacking 'github:esp0xdeadbeef/network-compiler/22dbbbc350f5ec...' into the Git cache...
#   error: unable to download
#     'https://github.com/esp0xdeadbeef/network-compiler/archive/22dbbbc....tar.gz':
#     Could not resolve host: github.com
#
# The revision came from a SIBLING's lock, not from the test -- and a `github:` tarball
# and a git checkout of the same revision are different store paths, so the sibling
# checkout CI already made can never satisfy it.
#
# CI checks out every sibling next to this repository, so the input path is simply that
# directory. `flake archive` stays as a fallback for a developer machine without the
# sibling present, which is the only case where resolving the locked graph is correct.
flake_input_path() {
  local input_name="${1:?input name required}"
  local root="${2:?repository root required}"
  local sibling
  sibling="$(cd "$(dirname "${root}")" 2>/dev/null && pwd)/${input_name}"
  if [[ -f "${sibling}/flake.nix" ]]; then
    printf '%s\n' "${sibling}"
    return 0
  fi
  flake-archive-offline --json "path:${root}" | jq -er ".inputs[\"${input_name}\"].path"
}
