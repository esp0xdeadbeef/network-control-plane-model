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

  deploymentHosts = if inventory ? deployment && inventory.deployment ? hosts then inventory.deployment.hosts else { };
  hatEndpointAssignment = import ./cpm/hat-endpoint-assignment.nix {
    inherit deploymentHosts;
    lib = effectiveLib;
  };

  merged = {
    control_plane_model = cpm;
    endpointInventory = inventory;
    inherit deploymentHosts;
  }
  // (effectiveLib.optionalAttrs (hatEndpointAssignment != { }) {
    endpointAssignment = hatEndpointAssignment;
  });
in
builtins.seq cpm merged
