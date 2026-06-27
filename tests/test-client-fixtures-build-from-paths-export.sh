#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

system="${SYSTEM:-x86_64-linux}"

shape="$(
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake (toString ./.);
      system = \"${system}\";
      bySystem = flake.libBySystem.\${system}.clientFixtures;
      topLevel = flake.clientFixtures;
    in
    {
      bySystemBuildFromPaths = builtins.hasAttr \"buildFromPaths\" bySystem;
      bySystemHostModuleFromPaths = builtins.hasAttr \"hostModuleFromPaths\" bySystem;
      topLevelBuildFromPaths = builtins.hasAttr \"buildFromPaths\" topLevel;
      topLevelHostModuleFromPaths = builtins.hasAttr \"hostModuleFromPaths\" topLevel;
    }
  "
)"

if ! jq -e '
  .bySystemBuildFromPaths == true and
  .bySystemHostModuleFromPaths == true and
  .topLevelBuildFromPaths == true and
  .topLevelHostModuleFromPaths == true
' <<<"${shape}" >/dev/null; then
  echo "FAIL clientFixtures API does not export buildFromPaths and hostModuleFromPaths" >&2
  echo "${shape}" >&2
  exit 1
fi

echo "PASS clientFixtures exports buildFromPaths and hostModuleFromPaths"
