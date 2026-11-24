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
  canonicalOverlays = import ./cpm/canonical-overlays.nix { inherit lib; } cpm;
  canonicalSites = import ./cpm/canonical-sites.nix { inherit lib; } cpm;
  canonicalRuntimeTargets = import ./cpm/canonical-runtime-targets.nix { inherit lib; } cpm;
  canonicalForwarding = import ./cpm/canonical-forwarding.nix { inherit lib; } cpm;

  deploymentHosts = if inventory ? deployment && inventory.deployment ? hosts then inventory.deployment.hosts else { };
  hatEndpointAssignment = import ./cpm/hat-endpoint-assignment.nix {
    inherit deploymentHosts;
    lib = effectiveLib;
  };

  merged = {
    # The artifact carries its control-plane model under TWO names: the historical
    # `control_plane_model`, and `model`, which is simply what it is.
    #
    # A consumer that needs model fields had to spell `control_plane_model`, and a
    # reader -- human or a gate -- cannot tell that apart from a renderer reaching
    # into the plain CPM, which RR_RAW_CPM_INPUT forbids. Publishing a neutral alias
    # lets a consumer name the thing it wants instead of the stage that produced it.
    # Same value under both names; nothing about the artifact changes.
    model = cpm // { inherit canonicalInterfaces canonicalRoutes canonicalOverlays canonicalSites canonicalRuntimeTargets canonicalForwarding; };
    control_plane_model = cpm // { inherit canonicalInterfaces canonicalRoutes canonicalOverlays canonicalSites canonicalRuntimeTargets canonicalForwarding; };
    endpointInventory = inventory;
    inherit deploymentHosts;
  }
  // (effectiveLib.optionalAttrs (hatEndpointAssignment != { }) {
    endpointAssignment = hatEndpointAssignment;
  });
in
builtins.seq cpm merged
