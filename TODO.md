Temporary boundary violations (currently in the main NixOS repo):

1. Transit VLAN IDs are currently derived locally from a formula.
2. Tenant VLAN IDs are currently derived locally from the IPv4 tenant subnet shape.

Reason:
needed to finish access/policy router realization before `network-control-plane-model` emits explicit VLAN data needed by the NixOS modules.

Constraint:
these derivations must exist in exactly one helper each and must not be reimplemented in host/container/router modules.

Exit criteria:
remove the transit VLAN helper after `network-control-plane-model` emits explicit per-interface transit VLAN IDs.
remove the tenant VLAN helper after `network-control-plane-model` emits explicit tenant VLAN IDs for rendered interfaces or networks.
