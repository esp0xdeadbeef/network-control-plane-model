{
  lib,
  helpers,
  common,
  ipam,
  sitePath,
  siteAttrs,
  allSiteEntries,
  allRuntimeRoutedIPv6Prefixes,
  siteOverlayNameSet,
  overlayExitPeerSiteByName,
  runtimeTargetNames,
  runtimeTargetsWithWANDefaults,
  transitEndpointAddressesByNode,
  sortedCandidatePaths,
  preferredFirstHopMatchesSource,
  explicitDefaultSourceSet4,
  explicitDefaultSourceSet6,
  delegatedSourceUsesOverlayEgress,
  isDelegatedIPv6AccessNode,
  runtimeRoutedIPv6AccessNodeNames,
  runtimeRoutedIPv6PrefixesByAccessNode,
  routeHelpers,
}:

let
  inherit (helpers) requireAttrs;
  inherit (common)
    attrsOrEmpty
    ;
  explicitDefaultPreservation = import ./explicit-default-preservation.nix {
    inherit helpers common sitePath siteOverlayNameSet isDelegatedIPv6AccessNode;
  };

  targetInterfaces = targetPath: target:
    let
      effective = requireAttrs "${targetPath}.effectiveRuntimeRealization" (target.effectiveRuntimeRealization or null);
    in
    {
      inherit effective;
      interfaces = requireAttrs "${targetPath}.effectiveRuntimeRealization.interfaces" (effective.interfaces or null);
    };

  defaultRouteSanitizer = import ./default-route-sanitizer.nix {
    inherit common helpers isDelegatedIPv6AccessNode siteOverlayNameSet targetInterfaces;
  };
  delegatedOverlayEgress = import ./delegated-overlay-egress.nix {
    inherit helpers common siteOverlayNameSet overlayExitPeerSiteByName;
  };
  overlayExitIngress = import ./overlay-exit-ingress.nix {
    inherit helpers common ipam siteOverlayNameSet;
  };
  endpointRoutes = import ./endpoint-routes.nix {
    inherit
      helpers
      common
      sitePath
      targetInterfaces
      transitEndpointAddressesByNode
      sortedCandidatePaths
      preferredFirstHopMatchesSource
      routeHelpers
      ;
  };
  runtimeRoutedPrefixRoutes = import ./runtime-routed-prefix-routes.nix {
    inherit
      lib
      helpers
      common
      sitePath
      siteAttrs
      allSiteEntries
      allRuntimeRoutedIPv6Prefixes
      siteOverlayNameSet
      sortedCandidatePaths
      preferredFirstHopMatchesSource
      routeHelpers
      runtimeRoutedIPv6PrefixesByAccessNode
      ;
  };
  inherit (defaultRouteSanitizer)
    sanitizeDefaultRoutesForInterface
    sanitizeOverlayDefaults
    ;
  internalDefaults = import ./internal-defaults.nix {
    inherit
      helpers
      common
      sitePath
      siteAttrs
      allRuntimeRoutedIPv6Prefixes
      siteOverlayNameSet
      delegatedSourceUsesOverlayEgress
      isDelegatedIPv6AccessNode
      runtimeRoutedIPv6AccessNodeNames
      sortedCandidatePaths
      preferredFirstHopMatchesSource
      targetInterfaces
      sanitizeDefaultRoutesForInterface
      sanitizeOverlayDefaults
      delegatedOverlayEgress
      overlayExitIngress
      routeHelpers
      ;
  };

  buildTarget = targetName:
    let
      target0 = runtimeTargetsWithWANDefaults.${targetName};
      target1 = endpointRoutes.add 4 targetName target0;
      target2 = endpointRoutes.add 6 targetName target1;
      target3 = internalDefaults.add 4 explicitDefaultSourceSet4 targetName target2;
      target4 = internalDefaults.add 6 explicitDefaultSourceSet6 targetName target3;
      target5 = runtimeRoutedPrefixRoutes.add targetName target4;
      target6 = explicitDefaultPreservation.restore { inherit targetName; originalTarget = target0; resolvedTarget = target5; };
      target7 = internalDefaults.markTargetPolicyDefaults target6;
    in
    { name = targetName; value = target7; };

in
{
  runtimeTargetsWithSynthesizedDefaults = builtins.listToAttrs (builtins.map buildTarget runtimeTargetNames);
}
