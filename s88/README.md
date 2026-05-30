# network-control-plane-model S88 Boundary

`network-control-plane-model` owns renderer-neutral control-plane contracts
after compiler and NFM output have established network meaning.

## Enterprise

Enterprise and site data are assembled by `src/build-cpm.nix`,
`src/merge-inputs.nix`, and `src/cpm/build-site-data.nix`.

## Site

Site-level CPM contracts are built under `src/cpm/Site/`, including overlay
provisioning and provider bootstrap contracts.

## Unit

Runtime targets, interfaces, routes, route tables, policy rules, DNS services,
NAT intent, firewall intent, endpoint bindings, and realization facts are
normalized under `src/cpm/Unit/` and `src/cpm/ControlModule/`.

## ControlModule

Control modules validate and project renderer-neutral contracts only. They must
not render NixOS, Containerlab, Nebula, or WireGuard syntax.

