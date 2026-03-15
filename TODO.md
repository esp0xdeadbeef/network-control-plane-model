# TODO

This document lists the functionality that must be implemented for the control plane model.

All implementations must be written in **Nix**.

No implementation in Python or shell is permitted.

---

# Core responsibilities

The control plane model must derive routing behavior from the forwarding model.

The following capabilities must be implemented.

---

## Routing adjacency construction

Determine which nodes establish routing relationships.

Adjacency construction must be derived from:

- transit adjacency ordering
- node roles
- forwarding adjacency graph

The result must describe:

- adjacency endpoints
- adjacency direction
- adjacency role

---

## Routing hierarchy

Determine routing hierarchy based on forwarding structure.

Examples of hierarchy patterns:

access → policy  
policy → upstream selector  
upstream selector → core  

Hierarchy must determine:

- which nodes originate routes
- which nodes propagate routes
- which nodes aggregate routes

---

## Prefix advertisement responsibilities

Determine which node advertises which prefixes.

This must be derived from:

- prefix ownership
- forwarding reachability
- role responsibilities

Responsibilities include:

- tenant prefix advertisement
- loopback advertisement
- uplink route injection

---

## Route propagation graph

Construct the routing propagation graph.

This graph determines:

- how routes flow through the network
- where routes may be filtered
- where routes must propagate

The propagation graph must match the forwarding traversal model.

---

## Protocol abstraction

The control plane model must support protocol abstraction.

The model should allow implementation of routing protocols such as:

- static routing
- iBGP
- eBGP
- IS-IS
- future protocols

The model must not depend on any specific routing protocol.

Protocol selection should occur **after control plane topology is defined**.

---

## Session description

The model must describe routing sessions.

Each session should define:

- participating nodes
- session role
- session direction
- session purpose

---

## Route import/export behavior

The model must define:

- which routes a node imports
- which routes a node exports
- propagation scope

Policy evaluation itself is **not performed here**.

This layer only defines routing mechanics.

---

## Renderer boundary enforcement

The control plane model must ensure renderers do not invent routing structure.

Renderers must receive:

- complete routing adjacency definitions
- prefix advertisement rules
- propagation relationships

Renderers should only translate this model into platform syntax.

---

# Code migration required

Some logic currently exists inside renderer implementations.

Parts of this logic must be moved into the control plane model.

Typical examples include:

- BGP neighbor derivation
- route redistribution logic
- adjacency construction
- prefix advertisement selection

Renderer implementations must become **pure translation layers**.

---

# Validation requirements

Evaluation must fail if:

- forwarding adjacency is inconsistent
- prefix ownership is ambiguous
- routing hierarchy cannot be derived
- propagation graph is cyclic where not allowed

All validation must occur during Nix evaluation.

---

# Deliverables

This repository must eventually produce:

- a deterministic control plane model
- a schema describing control plane structure
- Nix modules implementing the control plane construction
