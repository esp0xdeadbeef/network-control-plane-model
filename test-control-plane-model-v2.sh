#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"

fixture_root=./fixtures/passing/control-plane-hosted-node
output=./output-control-plane-model.json

nix eval --impure --json --expr "
  let
    main = import ./src/main.nix;
    input = import ${fixture_root}/input.nix;
    inventory = import ${fixture_root}/inventory.nix;
  in
  main {
    inherit input inventory;
  }
" > "${output}"

jq -e '.control_plane_model.runtime.targets | keys | length > 0' "${output}" >/dev/null
jq -e '.control_plane_model.runtime.targets["s-router-policy"]' "${output}" >/dev/null
jq -e '.control_plane_model.runtime.targets["s-router-policy"].logicalNode == {"enterprise":"esp0xdeadbeef","site":"site-a","name":"s-router-policy"}' "${output}" >/dev/null
jq -e '(.control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.interfaces | type) == "object" and ((.control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.interfaces | keys | length) > 0)' "${output}" >/dev/null
jq -e '(.control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.runtimePorts | type) == "array" and ((.control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.runtimePorts | length) > 0)' "${output}" >/dev/null
jq -e '
  .control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.interfaces
  | to_entries
  | all(
      .value
      | has("runtimeInterface")
      and has("logicalInterfaces")
      and has("link")
      and has("attachment")
    )
' "${output}" >/dev/null
jq -e '
  .control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.runtimePorts
  | all(has("runtimePort") and has("runtimeInterface"))
' "${output}" >/dev/null
