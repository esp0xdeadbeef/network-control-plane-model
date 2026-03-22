<!-- ./TODO.md -->

## Current status (measurable)

### Verified from current output
- [x] `control_plane_model.runtime` exists in `output-control-plane-model.json`
- [x] `control_plane_model.runtime.targets` exists in `output-control-plane-model.json`
- [x] `control_plane_model.runtime.targets` is currently exactly `{}` in `output-control-plane-model.json`
- [x] `src/main.nix` passes an inventory value into `deriveCPM`
- [x] `src/build-cpm.nix` adds a `runtime` section to the emitted CPM
- [x] `src/build-cpm.nix` attempts to read inventory realization data
- [x] `src/build-cpm.nix` attempts to resolve runtime targets to logical nodes

### Not yet verified from current output
- [ ] At least 1 runtime target is emitted under `control_plane_model.runtime.targets`
- [ ] At least 1 emitted runtime target has a non-empty `logicalNode`
- [ ] At least 1 emitted runtime target has a non-empty `effectiveRuntimeRealization.interfaces`
- [ ] At least 1 emitted runtime target has a non-empty `effectiveRuntimeRealization.runtimePorts`

## Concrete deliverables

### 1. Emit at least one runtime target in the CPM
- [ ] Add or fix fixture input so that `output-control-plane-model.json` contains:
  - `control_plane_model.runtime.targets.s-router-policy`
- [ ] Acceptance check:
  - this command succeeds:
    `jq -e '.control_plane_model.runtime.targets["s-router-policy"]' output-control-plane-model.json >/dev/null`

### 2. Emit explicit logical-node mapping for that target
- [ ] Ensure `control_plane_model.runtime.targets.s-router-policy.logicalNode` equals:
  - `{"enterprise":"esp0xdeadbeef","site":"site-a","name":"s-router-policy"}`
- [ ] Acceptance check:
  - this command succeeds:
    `jq -e '.control_plane_model.runtime.targets["s-router-policy"].logicalNode == {"enterprise":"esp0xdeadbeef","site":"site-a","name":"s-router-policy"}' output-control-plane-model.json >/dev/null`

### 3. Emit runtime-facing interfaces for that target
- [ ] Ensure `control_plane_model.runtime.targets.s-router-policy.effectiveRuntimeRealization.interfaces` exists
- [ ] Ensure it is not empty
- [ ] Acceptance check:
  - this command succeeds:
    `jq -e '(.control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.interfaces | type) == "object" and ((.control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.interfaces | keys | length) > 0)' output-control-plane-model.json >/dev/null`

### 4. Emit runtime ports for that target
- [ ] Ensure `control_plane_model.runtime.targets.s-router-policy.effectiveRuntimeRealization.runtimePorts` exists
- [ ] Ensure it is not empty
- [ ] Acceptance check:
  - this command succeeds:
    `jq -e '(.control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.runtimePorts | type) == "array" and ((.control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.runtimePorts | length) > 0)' output-control-plane-model.json >/dev/null`

### 5. Emit explicit per-interface attachment/link data
For every entry under:
- `control_plane_model.runtime.targets.s-router-policy.effectiveRuntimeRealization.interfaces`

each interface object must contain:
- [ ] `runtimeInterface`
- [ ] `logicalInterfaces`
- [ ] `link`
- [ ] `attachment`

Acceptance checks:
- [ ] this command succeeds:
  `jq -e '
    .control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.interfaces
    | to_entries
    | all(
        .value
        | has("runtimeInterface")
        and has("logicalInterfaces")
        and has("link")
        and has("attachment")
      )
  ' output-control-plane-model.json >/dev/null`

### 6. Emit explicit runtimePort -> runtimeInterface mapping
For every entry under:
- `control_plane_model.runtime.targets.s-router-policy.effectiveRuntimeRealization.runtimePorts[]`

each runtime port object must contain:
- [ ] `runtimePort`
- [ ] `runtimeInterface`

Acceptance checks:
- [ ] this command succeeds:
  `jq -e '
    .control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.runtimePorts
    | all(has("runtimePort") and has("runtimeInterface"))
  ' output-control-plane-model.json >/dev/null`

### 7. Prove the inventory realization path used by this repo
Choose one canonical input shape and make the fixture use it.

Canonical shape to keep:
- [x] `inventory.realization.nodes.<runtime-target>`

Shapes to remove from implementation after fixture passes:
- [x] `inventory.deployment.realization`
- [x] top-level `inventory.nodes`
- [x] nested `inventory.inventory`
- [x] nested `inventory.evaluated`
- [x] nested `inventory.rendered`

Acceptance checks:
- [ ] fixture input contains `inventory.realization.nodes.s-router-policy`
- [x] `src/build-cpm.nix` reads only the canonical realization path
- [x] grep confirms removed fallbacks:
  - `grep -q 'deployment.realization' src/build-cpm.nix` must fail
  - `grep -q 'inventoryRoot.nodes' src/build-cpm.nix` must fail
  - `grep -q 'inventory.evaluated' src/build-cpm.nix` must fail
  - `grep -q 'inventory.rendered' src/build-cpm.nix` must fail

### 8. Add one fixture that proves hosted-node rendering
- [ ] Add a fixture where runtime target `s-router-policy` hosts logical node `s-router-policy`
- [ ] Fixture must be used by `./test-control-plane-model.sh`
- [ ] Acceptance check:
  - running `./test-control-plane-model.sh` produces `output-control-plane-model.json`
  - and all acceptance checks in sections 1 through 6 pass

## Definition of done

This work is done only when all of these are true:

- [ ] `./test-control-plane-model.sh` exits with status 0
- [ ] `jq -e '.control_plane_model.runtime.targets | keys | length > 0' output-control-plane-model.json >/dev/null`
- [ ] `jq -e '.control_plane_model.runtime.targets["s-router-policy"]' output-control-plane-model.json >/dev/null`
- [ ] `jq -e '.control_plane_model.runtime.targets["s-router-policy"].logicalNode == {"enterprise":"esp0xdeadbeef","site":"site-a","name":"s-router-policy"}' output-control-plane-model.json >/dev/null`
- [ ] `jq -e '(.control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.interfaces | keys | length) > 0' output-control-plane-model.json >/dev/null`
- [ ] `jq -e '(.control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.runtimePorts | length) > 0' output-control-plane-model.json >/dev/null`
- [ ] `jq -e '
      .control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.interfaces
      | to_entries
      | all(
          .value
          | has("runtimeInterface")
          and has("logicalInterfaces")
          and has("link")
          and has("attachment")
        )
    ' output-control-plane-model.json >/dev/null`
- [ ] `jq -e '
      .control_plane_model.runtime.targets["s-router-policy"].effectiveRuntimeRealization.runtimePorts
      | all(has("runtimePort") and has("runtimeInterface"))
    ' output-control-plane-model.json >/dev/null`
- [x] `src/build-cpm.nix` uses only `inventory.realization.nodes.<runtime-target>` as the realization source
