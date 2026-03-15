# network-control-plane-model

> ⚠️ This module exists because forwarding behavior alone does not define how a network actually operates.

The **network-control-plane-model** converts a deterministic **Forwarding Model** into an explicit **Control Plane Model**.

The forwarding model describes **how packets must traverse the network fabric**.

The control plane model describes **how routing behavior is constructed so that forwarding becomes operational**.

This repository therefore defines the routing structure required to realize the forwarding model.

It produces a platform-neutral description of routing behavior.

No device configuration must be generated here.

---

# TLDR

Forwarding describes packet traversal.

Control plane describes how routing protocols make that traversal possible.

Renderers translate the result into device configuration.

---

# Architecture position

The network toolchain is divided into four layers.

Compiler  
↓  
Forwarding Model  
↓  
Control Plane Model  ← this repository  
↓  
Renderer  

Each layer has a strictly defined responsibility.

---

# Compiler

The compiler defines **communication intent**.

Examples include:

- tenants
- services
- traffic types
- communication contracts

The compiler answers the question:

Who must be able to communicate with whom?

The compiler does **not** define topology or routing behavior.

---

# Forwarding Model

The forwarding model constructs a **deterministic packet traversal structure**.

It defines:

- nodes
- roles
- adjacency ordering
- prefix ownership
- forwarding responsibilities
- interface addressing
- uplinks

The forwarding model answers:

How must packets move through the network so that communication intent becomes executable?

However, the forwarding model **does not define routing protocols**.

It describes forwarding behavior, not control-plane behavior.

---

# Control Plane Model

This repository constructs the **Control Plane Model**.

It converts the forwarding structure into explicit routing behavior.

This includes:

- routing adjacencies
- routing session topology
- routing hierarchy
- route propagation paths
- prefix advertisement responsibilities
- routing roles per node

The control plane model answers:

How do routing protocols realize the forwarding structure?

The result is **platform neutral** and must contain no configuration syntax.

---

# Renderer

Renderers translate the control plane model into **device configuration**.

Examples include:

- NixOS router configuration
- Containerlab node definitions
- FRR configuration
- vendor router configuration

Renderers must not invent routing structure.

They must consume the control plane model deterministically.

---

# Responsibilities of this repository

This repository must:

- consume the forwarding model
- derive routing adjacencies
- derive routing hierarchy
- determine route propagation structure
- determine prefix advertisement responsibilities
- determine routing protocol roles

This repository must **not**:

- generate device configuration
- define platform syntax
- allocate IP addresses
- modify forwarding behavior
- reinterpret communication intent

The forwarding model is authoritative.

---

# Implementation requirements

The control plane model **must be implemented entirely in Nix**.

This ensures:

- deterministic evaluation
- pure functional behavior
- reproducible builds
- schema validation through evaluation failure

The repository must not contain:

- Python
- shell orchestration
- imperative logic

All control-plane derivation must be expressed as **pure Nix evaluation**.

---

# Expected input

The input to this repository is the **Forwarding Model** produced by the upstream solver.

Typical structures include:

- nodes
- node roles
- transit adjacency ordering
- prefix ownership
- forwarding routes
- interface definitions
- uplink definitions
- topology metadata

The control plane model must treat the forwarding model as **authoritative**.

Forwarding behavior must not be modified.

---

# Expected output

The output of this repository must be a **Control Plane Model** describing routing behavior.

The model must contain structures such as:

- routing adjacencies
- routing sessions
- routing hierarchy
- prefix advertisement responsibilities
- route propagation relationships
- route import/export structure

The model must remain **platform neutral**.

Multiple renderers should be able to consume the same model and produce identical routing behavior.

---

# Missing forwarding model fields

Some information required for correct control plane construction is currently missing from the forwarding model schema.

These missing elements are documented in:

MISSING-FIELDS-NETWORK-FORWARDER.md

This file lists structural gaps in the forwarding model which must eventually be resolved upstream.

Examples include:

- explicit routing adjacency intent
- prefix advertisement scope
- route propagation boundaries
- routing capability declarations
- control-plane participation flags

These are **upstream schema issues**, not problems in this repository.

This repository must not attempt to compensate for them through ad-hoc heuristics.

---

# Repository structure

network-control-plane-model
LICENSE
README.md
TODO.md
MISSING-FIELDS-NETWORK-FORWARDER.md

---

# Design philosophy

This repository exists to remove ambiguity between forwarding behavior and routing behavior.

Forwarding models describe:

packet traversal.

Control plane models describe:

routing behavior required to make traversal possible.

Renderers describe:

device configuration.

Keeping these layers separate ensures:

- deterministic network construction
- renderer independence
- architectural clarity
- reproducible infrastructure
