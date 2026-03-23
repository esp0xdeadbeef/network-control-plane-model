# TODO — network-control-plane-model

## Current scope

This repo should consume the **network-forwarding-model output** and emit a **fully explicit, renderer-ready runtime realization**.

Its job is not to guess what the forwarding model meant.
Its job is to take the forwarding model contract as-is, validate it hard, and emit the exact runtime-facing structure needed downstream.

---

## Current status

The real work is no longer “just emit interfaces”.

The bigger problem is that the **input contract changed materially** and this repo must now be aligned to the new forwarding-model boundary:

* forwarding-model input now carries **stable link identities**
* `transit.ordering` is now expressed in **stable link IDs**
* `transit.adjacencies[]` now carries explicit `id`
* node `loopback` is now first-class and participates in ownership / uniqueness
* node/link data is more explicit and should reduce downstream inference
* older solver-era shapes still appear to influence this stage’s assumptions

The remaining work is mostly about:

* locking the new input contract
* deleting old solver-era assumptions
* making runtime realization canonical
* removing remaining inference / duplication
* separating validation authority from realization logic
* breaking oversized implementation units into clear modules
* covering the new contract with tests

---

## Hard assumptions

Backward compatibility for old forwarding-model input is not required.

* [ ] Do not preserve old solver-era shapes just because older examples emitted them
* [ ] Do not support both old and new transit-ordering contracts in parallel
* [ ] Do not preserve legacy field names if they blur the stage boundary
* [ ] Prefer deleting old assumptions over adding compatibility normalization
* [ ] Fail early when input does not match the intended forwarding-model contract

---

# 1. Lock the input contract to forwarding-model v6

## 1.1 Consume the new stage contract explicitly

* [ ] Treat `meta.networkForwardingModel` as the authoritative upstream contract marker
* [ ] Validate expected schema version before building runtime realization
* [ ] Document exactly which forwarding-model fields are required input to this stage

## 1.2 Stop depending on solver-era metadata

* [ ] Remove any dependency on `meta.solver`
* [ ] Remove code paths that assume older upstream naming or older stage ownership
* [ ] Ensure diagnostics talk about **forwarding model input**, not “solver output”

## 1.3 Required input fields to consume intentionally

* [ ] `enterprise.<enterprise>.site.<site>.nodes`
* [ ] `links`
* [ ] `transit.adjacencies`
* [ ] `transit.ordering`
* [ ] `attachments`
* [ ] `policyNodeName`
* [ ] `upstreamSelectorNodeName`
* [ ] `coreNodeNames`
* [ ] `uplinkCoreNames`
* [ ] `uplinkNames`
* [ ] `domains.tenants`
* [ ] `domains.externals`
* [ ] `tenantPrefixOwners`
* [ ] node `loopback`
* [ ] node `interfaces`

---

# 2. Remove old input-shape assumptions

## 2.1 Delete obsolete field expectations

* [ ] Remove support for legacy singular `attachment`
* [ ] Remove assumptions that input provides `topology.nodes`
* [ ] Remove assumptions that input provides `units`
* [ ] Remove assumptions that input provides site-local `id` when `siteName` / `siteId` are canonical
* [ ] Remove assumptions tied to older relation metadata such as positional/index-based source tracking if no longer needed

## 2.2 Stop reconstructing semantics from old shapes

* [ ] Do not derive transit ordering from node-pair topology if stable link IDs already exist
* [ ] Do not rebuild link identity from endpoint names if input already gives canonical IDs
* [ ] Do not depend on duplicated/legacy topology views when canonical node/link state already exists
* [ ] Do not infer loopbacks indirectly if node `loopback` is explicit

---

# 3. Make transit semantics fully canonical

This is one of the biggest boundary changes in the diff.

## 3.1 Stable link identity must be preserved end-to-end

* [ ] Treat `links.*.id` as canonical link identity
* [ ] Treat `transit.adjacencies[].id` as canonical adjacency identity
* [ ] Treat `transit.ordering` as canonical realized transit ordering
* [ ] Preserve stable link identity into any runtime-facing structures that need transit/link references

## 3.2 Remove pair-based transit logic

* [ ] Delete any remaining code that expects `transit.ordering` as node pairs
* [ ] Delete any fallback matching from `[nodeA, nodeB]` → realized link
* [ ] Reject old pair-based ordering input outright if backward compatibility is not needed
* [ ] Ensure no ambiguity remains in link selection for runtime realization

## 3.3 Validate input consistency

* [ ] Fail if `transit.ordering` contains anything other than stable link IDs
* [ ] Fail if any `transit.ordering` entry is missing from `transit.adjacencies[].id`
* [ ] Fail if any p2p adjacency is missing from ordering
* [ ] Fail if ordering contains duplicates
* [ ] Fail if adjacency IDs disagree with realized link IDs

---

# 4. Decide how loopbacks are represented in runtime realization

The diff shows loopbacks are now explicit on nodes and also affect ownership.

## 4.1 Make loopback handling intentional

* [ ] Decide whether runtime realization keeps loopbacks as a dedicated field or emits them as canonical interfaces
* [ ] If loopbacks are rendered as interfaces, document that as an explicit CPM contract
* [ ] If loopbacks remain separate, ensure renderer does not need to synthesize fake interfaces

## 4.2 Remove accidental synthetic behavior

* [ ] Audit any logic that creates synthetic `tenant-loopback` interfaces
* [ ] Decide whether synthetic loopback-as-tenant interfaces are still valid or are now contract leakage
* [ ] Ensure loopback handling is consistent across:

  * [ ] core nodes
  * [ ] policy nodes
  * [ ] upstream-selector nodes
  * [ ] access nodes

## 4.3 Validate loopback correctness

* [ ] Ensure runtime realization does not duplicate loopbacks in multiple shapes unless explicitly required
* [ ] Ensure loopback ownership agrees with `tenantPrefixOwners`
* [ ] Ensure explicit loopbacks do not require renderer inference

---

# 5. Define the canonical runtime target model

The repo should emit one clear runtime-facing structure, not fragments.

## 5.1 Canonical output

At minimum, emit:

* [ ] `effectiveRuntimeRealization.interfaces`

Also decide whether the canonical emitted runtime structure should include:

* [ ] loopbacks
* [ ] link identity references
* [ ] attachment identity references
* [ ] rendered interface naming
* [ ] runtime/container targeting
* [ ] isolation / placement metadata

## 5.2 Renderer contract guarantees

* [ ] all runtime-facing data must exist in one canonical structure
* [ ] renderer must not need to inspect unrelated source subtrees to understand one interface
* [ ] renderer must not infer connectivity from topology/node names
* [ ] renderer must not reconstruct transit/link mapping itself
* [ ] renderer must not invent loopback or attachment semantics

---

# 6. Canonical interface schema

Each emitted runtime interface must be explicit enough to render directly.

## 6.1 Required per-interface fields

* [ ] `runtimeIfName`
* [ ] `renderedIfName`
* [ ] explicit runtime target / unit association
* [ ] exactly one canonical backing reference type
* [ ] `addr4`
* [ ] `addr6`
* [ ] `routes`

## 6.2 Backing reference rules

Decide the canonical backing reference model.

* [ ] exactly one of `link` or `attachment`
* [ ] reject interfaces that have neither
* [ ] reject interfaces that have both
* [ ] if loopbacks are emitted as interfaces, define whether they use a third explicit kind instead of overloading tenant semantics

## 6.3 Eliminate ambiguity

* [ ] one emitted interface must map to one clear source concept
* [ ] interface identity must not depend on sibling lookup or renderer-side joining
* [ ] source-to-runtime mapping must be deterministic

---

# 7. Stop leaking duplicated topology into the output

The diff suggests this stage may still duplicate structural views (`topology.nodes`, `units`, isolated/unit summaries, etc.).

## 7.1 Decide what belongs in CPM output

* [ ] decide whether `topology.nodes` belongs in CPM output at all
* [ ] decide whether `units` belongs in CPM output at all
* [ ] decide whether isolated/container placement should be emitted separately or folded into runtime target definitions

## 7.2 Remove duplicate mirrors

* [ ] do not emit multiple structural views of the same runtime fact unless there is a hard downstream need
* [ ] remove output duplication that can drift out of sync
* [ ] make one structure the source of truth for runtime placement

---

# 8. Containers / units / isolation mapping

The diff shows strong runtime placement semantics (`containers`, `isolated`, default vs isolated-0, etc.).

## 8.1 Make runtime placement explicit

* [ ] define canonical runtime target identity
* [ ] define how node → unit/container mapping is represented
* [ ] define how isolation state is represented
* [ ] ensure interface emission points to the actual runtime target, not just the logical node

## 8.2 Remove hidden placement inference

* [ ] renderer must not infer container placement from naming conventions
* [ ] runtime target/container selection must not depend on fallback rules
* [ ] isolated/default placement must be explicit and validated

---

# 9. Route handling

The diff shows route sets are already highly explicit. That should reduce downstream logic.

## 9.1 Treat routes as authoritative emitted data

* [ ] consume per-interface routes as authoritative input where appropriate
* [ ] do not re-derive routes from topology if the forwarding model already emitted them
* [ ] ensure runtime interface output preserves route information losslessly where needed by renderer

## 9.2 Validate route/interface consistency

* [ ] fail if routes are missing from an interface that is supposed to be render-complete
* [ ] fail if route family/data does not match interface family/data
* [ ] ensure uplink/default/internal/connected semantics survive the stage boundary cleanly

---

# 10. Naming guarantees

## 10.1 Rendered naming

* [ ] `renderedIfName` must be deterministic
* [ ] `renderedIfName` must be unique per runtime target
* [ ] naming must not depend on incidental attr ordering
* [ ] naming must not depend on old solver-era path assumptions

## 10.2 Runtime naming

* [ ] `runtimeIfName` must be explicit
* [ ] `runtimeIfName` must be stable for unchanged input
* [ ] relationship between source interface name and runtime/rendered name must be documented

---

# 11. Validation authority and module boundaries

The current refactor direction improves explicitness, but it also risks turning `build-cpm.nix` into another god-file while duplicating contract checks.

## 11.1 Pick one validation authority

* [ ] decide whether forwarding-model contract validation lives in `invariants/default.nix` or in the CPM builder path
* [ ] remove duplicate schema checks implemented in multiple places
* [ ] ensure one malformed input shape produces one authoritative failure path
* [ ] ensure error wording is consistent for the same contract failure

## 11.2 Split oversized implementation units

* [ ] split `src/build-cpm.nix` by responsibility instead of letting one file own all realization logic
* [ ] separate input validation from realization assembly
* [ ] separate transit canonicalization from runtime-target construction
* [ ] separate attachment/link backing-reference resolution from interface emission
* [ ] keep file names aligned to responsibilities, not generic helpers

## 11.3 Keep defaults honest

* [ ] audit fallback/default placement behavior and decide whether each fallback is truly contractual or accidental inference
* [ ] reject semantic defaults that hide missing realization data
* [ ] keep purely serialization-level defaults clearly isolated from model semantics

---

# 12. Validation behavior

This stage should fail hard on contract mismatch instead of trying to be helpful.

## 12.1 Input contract failures

* [ ] missing `meta.networkForwardingModel`
* [ ] unsupported forwarding-model schema version
* [ ] missing stable link IDs
* [ ] pair-based transit ordering received where stable IDs are required
* [ ] missing node loopback where downstream contract expects it
* [ ] missing required node/interface/link fields

## 12.2 Runtime realization failures

* [ ] missing `runtimeIfName`
* [ ] missing `renderedIfName`
* [ ] missing `addr4`
* [ ] missing `addr6`
* [ ] missing `routes`
* [ ] ambiguous backing reference
* [ ] duplicate rendered interface names
* [ ] invalid runtime target/container placement
* [ ] orphan emitted interface
* [ ] output still requiring renderer inference

## 12.3 Error quality

* [ ] identify enterprise/site/target/interface in every failure
* [ ] distinguish input contract failure from runtime realization failure
* [ ] distinguish old-contract input from malformed new-contract input

---

# 13. Inventory boundary cleanup

Inventory validation is now closer to canonical stable link IDs, but transitional alias handling should not become permanent ambiguity.

## 13.1 Canonical inventory references

* [ ] decide whether inventory is allowed to reference only canonical stable link IDs or whether aliases remain temporarily accepted
* [ ] if aliases remain temporarily accepted, document that they are transitional only
* [ ] ensure full coverage is enforced against canonical stable link IDs, not display names

## 13.2 Remove long-term alias ambiguity

* [ ] avoid permanently normalizing legacy inventory refs if the intended boundary is stable IDs only
* [ ] keep alias mapping narrow, explicit, and easy to delete
* [ ] add a follow-up task to remove alias compatibility once fixtures/examples are migrated

---

# 14. Test coverage driven by this diff

## 14.1 Input migration tests

* [ ] current forwarding-model v6 sample input is accepted
* [ ] old node-pair `transit.ordering` input is rejected
* [ ] missing `transit.adjacencies[].id` is rejected
* [ ] missing `links.*.id` is rejected if CPM depends on it
* [ ] old `meta.solver`-only input is rejected or explicitly unsupported
* [ ] legacy singular `attachment` input is rejected

## 14.2 Loopback tests

* [ ] explicit node loopbacks are consumed correctly
* [ ] loopbacks are not silently duplicated into multiple output shapes
* [ ] loopback ownership matches `tenantPrefixOwners`
* [ ] loopback handling is correct for core/policy/upstream-selector nodes

## 14.3 Runtime placement tests

* [ ] isolated targets are emitted correctly
* [ ] default/non-isolated targets are emitted correctly
* [ ] interface → runtime target mapping is explicit and stable
* [ ] renderer can consume output without guessing target placement

## 14.4 Determinism tests

* [ ] same forwarding-model input produces byte-stable output
* [ ] stable link IDs are preserved unchanged
* [ ] interface naming is stable across repeated runs
* [ ] runtime target ordering, if emitted, is deterministic

## 14.5 Refactor safety tests

* [ ] split-out builder modules preserve byte-identical output for unchanged fixtures
* [ ] validation authority changes do not silently broaden accepted input
* [ ] deleting alias compatibility fails only the intended legacy cases

---

# 15. Documentation

## 15.1 README

* [ ] describe exact forwarding-model input contract this stage consumes
* [ ] document stable-link-id transit semantics
* [ ] document loopback handling
* [ ] document runtime target / isolation semantics
* [ ] document canonical runtime interface schema
* [ ] document that old solver-era input shapes are not supported

## 15.2 Developer notes

* [ ] add a short note explaining the contract jump from old solver-ish shapes to forwarding-model v6
* [ ] document which upstream fields are canonical and which old assumptions were deleted
* [ ] document why node-pair transit ordering is no longer accepted
* [ ] document where validation authority lives and why
* [ ] document planned module/file splits for `build-cpm.nix`

---

# 16. Suggested implementation order

* [ ] lock the forwarding-model v6 input contract in writing
* [ ] choose one validation authority and delete duplicated checks
* [ ] remove old pair-based transit handling
* [ ] decide and document loopback representation
* [ ] define the canonical runtime target/interface schema
* [ ] split oversized builder logic into clear modules
* [ ] remove duplicated structural output
* [ ] hard-fail invalid or legacy input shapes
* [ ] narrow or delete transitional inventory alias handling
* [ ] add migration/regression tests from the provided diff
* [ ] clean up README

---

# Done when

* [ ] this repo consumes forwarding-model v6 intentionally, not accidentally
* [ ] no old solver-era input assumptions remain
* [ ] stable transit link identities are preserved end-to-end
* [ ] loopbacks are handled explicitly and consistently
* [ ] runtime realization is fully canonical and renderer-ready
* [ ] renderer does not need to infer connectivity, placement, or naming
* [ ] contract validation has one clear authority
* [ ] builder logic is split by responsibility instead of living in one giant file
* [ ] the new boundary is locked with targeted regression tests

