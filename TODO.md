
Implement TODO point 1,2 and 3 of the core invariants, for now, only warn if there are errors, but please only warn once, not 30 times over the same error (isa-18 style).

# TODO — network-control-plane-model

## Purpose

Consume **network-forwarding-model (v6)** and emit a **fully explicit, deterministic control-plane model**.

The control-plane model:

* does not infer
* does not repair
* does not guess intent
* does not silently normalize ambiguous input

It validates explicit forwarding input and elevates it into explicit runtime semantics.

---

## Normative end-state

The end-state contract is strict:

* missing required intent is a hard error
* renderer performs zero decision-making
* emitted runtime data is explicit, canonical, and deterministic
* compatibility paths do not define accepted model semantics

The README remains the canonical contract.

---

## Migration policy

Until the model is fully explicit, rollout is **warn first, then fail hard**.

This means:

* missing canonical authority is surfaced as a warning or design-assumption alarm
* warning paths may temporarily preserve current behavior so the system remains usable
* warnings must identify the exact missing explicit authority
* every warning path must correspond to a future hard-fail condition
* warning behavior is migration scaffolding only, not normative model behavior

Done state for migration:

* zero warnings
* zero renderer-derived semantics
* all current warning conditions converted to hard validation failures where required by the contract

---

## Core invariants

### 1. No inference anywhere

* [] No topology-based inference
* [] No name-based inference
* [] No route-pattern inference
* [] No role-based semantic repair
* [] No fallback/default semantics in canonical output
* [] If meaning is not explicit, emit a migration warning now and fail hard in the strict end-state

### 2. Forwarding-model is the only authority

* [] Require `meta.networkForwardingModel` with schema v6
* [] Reject solver-era input (`meta.solver`, pair-based transit, legacy transit shapes, implicit compatibility inputs)
* [] Consume only canonical forwarding-model authorities
* [] Consume DHCP/SLAAC/RA intent only from explicit forwarding-model fields once modeled
* [] Do not treat renderer-era defaults as model authority

Canonical authorities to consume explicitly:

* [] `enterprise`
* [] `enterprise.<name>.site`
* [] `site.nodes`
* [] `site.links`
* [] `site.transit.adjacencies`
* [] `site.transit.ordering`
* [] `site.attachments`
* [] `site.domains`
* [] `site.tenantPrefixOwners`
* [] `site.loopback` / node `loopback`
* [] node `interfaces`

### 3. Stable link identity is absolute

* [] Use `links.*.id` and `transit.adjacencies[].id` as canonical identity
* [] Require `transit.ordering` to reference stable link IDs only
* [] Reject pair-based ordering
* [] Fail on missing IDs
* [] Fail on duplicate IDs
* [] Fail on inconsistent link / adjacency identity references
* [] Ensure emitted runtime backing references preserve canonical identity without renderer-side resolution

### 4. Runtime model must be fully explicit

Each emitted interface must include:

* [] `runtimeIfName`
* [] `renderedIfName`
* [] `runtimeTarget`
* [] exactly one backing reference (`link` or `attachment`)
* [] explicit semantic role / kind
* [] `addr4`
* [] `addr6`
* [] `routes`
* [] canonical explicit interface semantics needed by renderers

Renderer must not:

* [] inspect topology
* [] resolve links
* [] infer placement
* [] infer interface roles
* [] infer policy bindings
* [] infer advertisement data
* [] infer NAT intent
* [] infer forwarding intent

### 5. Semantic elevation is CPM responsibility

CPM converts structure into explicit behavior.

#### Interfaces

* [] Require explicit interface role / kind in canonical input semantics
* [] Do not infer interface role from naming, topology, route shape, or placement
* [] Emit canonical semantic interface data for every runtime interface

#### Routes

* [] Do not rely on semantic interpretation of `proto`
* [] Routes must carry explicit intent where intent matters (`default`, `internal`, `egress`, etc.)
* [] Renderer must not derive egress or policy meaning from route patterns

#### Egress

* [] Require explicit per-node egress definition where egress behavior matters
* [] Renderer must not derive egress from routes, WAN presence, or interface classification

### 6. Loopbacks are first-class

* [] Consume node `loopback` explicitly
* [] Do not synthesize loopbacks
* [] Keep loopback representation consistent in emitted runtime model
* [] Validate ownership against `tenantPrefixOwners` where applicable
* [] Ensure loopback identity is renderer-ready without cross-tree reconstruction

### 7. Validation is strict and centralized

* [] Keep a single validation authority in CPM
* [] Fail on contract mismatch in the strict end-state
* [] Do not perform compatibility normalization that changes accepted meaning
* [] During migration, downgrade selected future hard errors to warnings only when explicitly intentional and traceable

### 8. Output must be renderer-ready

* [] Make all runtime data available in one canonical structure
* [] Require no cross-tree lookups in renderers
* [] Eliminate duplicated topology views used only for renderer recovery
* [] Keep emitted runtime semantics sufficient for direct rendering without policy reconstruction

---

## Explicit authority that still needs to move into CPM

### Access forwarding intent

* [] Emit explicit access firewall forwarding intent for access nodes
* [] Encode tenant/local-adapter to uplink forwarding explicitly
* [] Encode reverse forwarding explicitly where intended
* [] Encode MSS clamping intent explicitly
* [] Remove renderer dependence on access role defaults

### Core NAT intent

* [] Emit explicit core NAT intent for core nodes
* [] Encode whether NAT is enabled explicitly
* [] Encode which interfaces participate in NAT explicitly
* [] Encode MSS clamping intent for NAT/uplink handling explicitly where required
* [] Remove renderer dependence on WAN presence and uplink IPv4 inference

### Upstream-selector forwarding intent

* [] Emit explicit upstream-selector forwarding intent
* [] Encode intended transit forwarding relationships explicitly
* [] Remove renderer dependence on upstream-selector full-mesh defaults

### DHCPv4 advertisement policy

* [] Emit explicit DHCPv4 advertisement policy and allocation for tenant-facing interfaces
* [] Include `enable`
* [] Include bind interface
* [] Include served subnet
* [] Include pool
* [] Include router
* [] Include `dnsServers`
* [] Include `domain`
* [] Include stable allocation identity
* [] Remove renderer synthesis of pools, router, DNS, subnet, and allocation identifiers

### IPv6 RA advertisement policy

* [] Emit explicit IPv6 RA advertisement policy for tenant-facing interfaces
* [] Include `enable`
* [] Include bind interface
* [] Include advertised prefixes
* [] Include RDNSS
* [] Include DNSSL / domain
* [] Remove renderer synthesis of prefixes and advertisement defaults

### Canonical policy endpoint authority

* [] Emit canonical `site.policy.interfaceTags` in CPM output
* [] Treat `site.policy.interfaceTags` as the canonical authority named by the README
* [] Stop relying on `communicationContract.interfaceTags` as a long-term substitute
* [] Emit explicit policy endpoint bindings for tenant, service, external, and upstream relations
* [] Remove renderer-side endpoint binding recovery from topology, attachments, ownership, naming, and token matching

---

## Warn-first retirement plan

These warning classes should disappear before hard-fail cutover:

* [] access forwarding defaults warnings
* [] core NAT defaults warnings
* [] upstream-selector forwarding defaults warnings
* [] DHCPv4 derived advertisement warnings
* [] IPv6 RA derived advertisement warnings
* [] policy endpoint binding authority-gap warnings

For each warning class:

* [] identify the missing canonical source field
* [] emit that field from CPM
* [] switch renderer use from derived behavior to explicit behavior
* [] keep warning until all fixtures and real inputs are explicit
* [] convert remaining warning condition into validation failure when migration reaches zero-warning state

---

## Done when

* [] forwarding-model v6 is consumed explicitly
* [] no solver-era assumptions remain
* [] no implicit semantics remain
* [] renderer performs zero decision-making
* [] output is deterministic and stable
* [] network-control-plane-model has fully explicit intent and zero runtime guesswork
* [] migration warnings are zero
* [] all normative README requirements are enforced as hard vali

