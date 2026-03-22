Temporary boundary violation (currently in the main NixOS repo):
transit VLAN IDs are currently derived locally from a formula.

Reason:
needed to finish access/policy router realization before CPM emits explicit transit VLANs.

Constraint:
this derivation must exist in exactly one helper and must not be reimplemented in host/container/router modules.

Exit criteria:
remove helper after `network-control-plane-model` emits explicit per-interface transit VLAN IDs.
