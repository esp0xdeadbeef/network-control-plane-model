{ lib }:

let
  common = import ./common.nix { inherit lib; };
  inherit (common) fail forceAll requireAttrs;

  transitInvariant = import ./transit.nix { inherit lib common; };
  forwardingSiteInvariant = import ./forwarding-site.nix { inherit lib common transitInvariant; };
  cpmRuntimeTargetsInvariant = import ./cpm-runtime-targets.nix { inherit lib common; };

  validateForwardingModelInput = input:
    let
      context = { };
      inputAttrs =
        if builtins.isAttrs input then
          input
        else
          fail context "forwarding model input must be an attribute set";
      meta = inputAttrs.meta or null;
      marker =
        if builtins.isAttrs meta && builtins.isAttrs (meta.networkForwardingModel or null) then
          meta.networkForwardingModel
        else
          fail context "forwarding model input requires meta.networkForwardingModel";
      schemaVersion = marker.schemaVersion or null;
      enterprise = requireAttrs context "enterprise" (inputAttrs.enterprise or null);
    in
    if schemaVersion != 9 then
      fail context "unsupported forwarding model schema version '${toString schemaVersion}' (expected 9)"
    else
      forceAll (
        builtins.map
          (enterpriseName:
            let
              enterpriseValue = requireAttrs { inherit enterpriseName; } "enterprise.${enterpriseName}" enterprise.${enterpriseName};
              siteRoot = requireAttrs { inherit enterpriseName; } "enterprise.${enterpriseName}.site" (enterpriseValue.site or null);
            in
            forceAll (
              builtins.map
                (siteName: forwardingSiteInvariant.validate enterpriseName siteName siteRoot.${siteName})
                (lib.attrNamesSorted siteRoot)
            ))
          (lib.attrNamesSorted enterprise)
      );

in
{
  inherit validateForwardingModelInput;
  validateCPMData = cpmRuntimeTargetsInvariant.validateData;
}
