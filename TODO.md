# ./TODO.md

- [x] Derive `control_plane_model.transit` automatically from `site.links`
- [ ] Add validation for non-p2p link kinds in CPM builder
- [ ] Support multi-site enterprise CPM generation
- [ ] Add overlay/transport modeling to CPM
- [ ] Add CPM schema validation tests

# Transition Mode: Python Reference → Nix Control Plane Model

This repository **does not execute Python**.
All Python files under `src/python-reference/` exist **only as historical reference** for understanding the current renderer behavior.

The **control-plane model must be implemented entirely in Nix**.

---

# Important Principle

The Python implementation is **documentation of existing behavior**, not part of the runtime system.

Nothing inside:

```
src/python-reference/
```

must ever be executed.

It is **read-only reference material** used to translate the logic into Nix.

---

# Purpose of the Python Reference

The files in:

```
src/python-reference/
```

represent the behavior currently used by the legacy renderer.

They allow developers to:

* inspect the current algorithms
* understand control-plane derivation
* replicate behavior in Nix
* compare old vs new outputs

They are **not authoritative**.

The **Forwarding Model** is authoritative.

---

# Expected Output

The repository produces:

```
output-control-plane-model.json
```

This file represents the **Control Plane Model** derived from the forwarding model.

The model describes:

* routing adjacencies
* routing hierarchy
* route propagation
* prefix advertisement
* routing protocol roles

The model must remain **platform neutral**.

---

# Compatibility Strategy

The existing renderer currently expects behavior derived from the Python implementation.

During the transition:

*The new Nix implementation may evolve the control-plane model.*

However, the **original output structure must remain preserved** so the existing renderer continues to function.

Instead of replacing the old structure, the Nix implementation **adds an additional field** to the existing output.

---

# Output Structure During Transition

The existing structure must remain unchanged.

The Nix control-plane model is added as a **new top-level field**.

Example:

```json
{
  "<existing fields>": "...",
  "<existing structure remains unchanged>": "...",

  "control_plane_model": {
    "version": 1,
    "source": "nix",
    "data": { ... }
  }
}
```

Key rules:

* The **legacy structure must remain untouched**.
* Existing renderers must still be able to read the file exactly as before.
* The new field simply **extends the file**.

This allows both systems to coexist during migration.

---

# Meaning of the Fields

### Existing Fields

These represent the behavior previously produced by the Python renderer logic.

They are preserved so that:

* existing renderers continue to function
* migration can happen incrementally
* debugging remains possible

They are effectively the **legacy renderer contract**.

### `control_plane_model`

This is the **new canonical model** produced by the Nix implementation.

This field represents the **future architecture**.

Renderers will gradually migrate to consume this model instead of the legacy structure.

---

# Why This Separation Exists

The Python implementation contains:

* heuristics
* renderer-specific assumptions
* historical artifacts

The new control-plane model must **not inherit these constraints unnecessarily**.

Keeping both outputs allows:

* controlled migration
* debugging during development
* validation against previous behavior
* discovering bugs in legacy logic

---

# Renderer Migration Strategy

Current renderer behavior:

```
Forwarding Model
      ↓
Python logic
      ↓
Renderer
```

During transition:

```
Forwarding Model
      ↓
Nix Control Plane Model
      ↓
Renderer
```

Renderers will gradually migrate from reading the **legacy structure** to reading:

```
control_plane_model
```

---

# Debugging Philosophy

The new Nix implementation **will likely expose bugs or inconsistencies** in the original Python logic.

This is expected.

During implementation of the new renderer, mismatches will naturally reveal issues in the old logic.

When discrepancies appear:

1. Inspect the Python reference implementation.
2. Determine whether the behavior is correct or accidental.
3. Fix the model or renderer accordingly.

The transition phase intentionally allows this discovery process.

---

# Rules for Developers

### Do

* Read Python reference files to understand behavior
* Reimplement algorithms in Nix
* Improve model clarity
* Detect bugs in legacy behavior

### Do Not

* Execute Python inside this repository
* Introduce runtime Python dependencies
* Modify the Python reference files

---

# End State

Once the renderer fully consumes the Nix model:

```
control_plane_model
```

the legacy structure can eventually be removed.

The architecture becomes:

```
Compiler
↓
Forwarding Model
↓
Control Plane Model (Nix)
↓
Renderer
```

The Python reference directory can then be deleted.

---

# Summary

* Python files exist **only for reference**
* Nix implementation is the **true control-plane model**
* The original output structure is preserved
* A new `control_plane_model` field is added
* Migration happens incrementally
* Bugs discovered during migration are expected
* Final system will be **pure Nix evaluation**

