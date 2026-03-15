# TODO — Load inventory from example repo instead of local endpoint-inventory.nix

## Problem

The control-plane-model currently imports a local file:

    endpoint-inventory.nix

This file was removed, but the code still references it:

    src/main.nix
    flake.nix

This causes evaluation failure:

    path '/nix/store/.../endpoint-inventory.nix' does not exist

Additionally, loading inventory from inside this repository breaks the intended pipeline layering.

Inventory should originate from the **example definition**, just like `intent.nix`.

Example location:

    network-labs/examples/<example>/inventory.nix

---

## Goal

Make `control-plane-model` a **pure transformation layer**.

It must **not read external files**.

All required inputs must be provided through the function interface.

---

## Required changes

### 1. Remove local inventory import

Delete references to:

    endpoint-inventory.nix

Specifically remove:

    src/main.nix
    flake.nix

Example removal:

```nix
endpointInventory = import ../endpoint-inventory.nix;
