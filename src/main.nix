# ./src/main.nix
{ input
, inventory ? { }
, lib ? { }
, validateForwardingModel ? true
, validateRuntimeModel ? false
, secretPlatformSubstrate ? "nixos"
,
}:

let
  localLib = import ../lib/utils.nix;
  effectiveLib = lib // localLib;

  deriveCPM = import ./build-cpm.nix { lib = effectiveLib; };

  cpm =
    builtins.addErrorContext
      "while building network-control-plane-model from the explicit network-forwarding-model input"
      (
        deriveCPM {
          forwardingModel = input;
          inherit inventory validateForwardingModel validateRuntimeModel secretPlatformSubstrate;
        }
      );

  # Canonical interface identity is a property of the modelled network, so the
  # producer publishes it. Peer renderers map it instead of deriving an identity
  # from a platform interface name or an adapter class (FS-310: a renderer must
  # not invent canonical meaning).
  canonicalInterfaces = import ./cpm/canonical-interfaces.nix { inherit lib; } cpm;
  canonicalRoutes = import ./cpm/canonical-routes.nix { inherit lib; } cpm;
  canonicalWireGuard = import ./cpm/canonical-wireguard.nix { inherit lib; } cpm;
  canonicalSites = import ./cpm/canonical-sites.nix { inherit lib; } cpm;
  canonicalRuntimeTargets = import ./cpm/canonical-runtime-targets.nix { inherit lib; } cpm;

  # Realization facts the access-endpoint renderer materializes: per host, the
  # bridge networks and uplinks declared for it. These live in the inventory's
  # deployment block, not in the model, and are published here so a renderer can
  # read canonical content instead of re-reading inventory or the model.
  canonicalDeployment = {
    hosts = (inventory.deployment or { }).hosts or { };
  };

  deploymentHosts = if inventory ? deployment && inventory.deployment ? hosts then inventory.deployment.hosts else { };
  hatEndpointAssignment = import ./cpm/hat-endpoint-assignment.nix {
    inherit deploymentHosts;
    lib = effectiveLib;
  };

  merged = {
    control_plane_model = cpm // { inherit canonicalInterfaces canonicalRoutes canonicalWireGuard canonicalSites canonicalRuntimeTargets; };
    endpointInventory = inventory;
    inherit deploymentHosts;
  }
  // (effectiveLib.optionalAttrs (hatEndpointAssignment != { }) {
    endpointAssignment = hatEndpointAssignment;
  });
in
builtins.seq cpm merged
