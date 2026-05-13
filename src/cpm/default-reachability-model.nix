{ lib, helpers }:

{ sitePath, siteAttrs, transit, runtimeTargets, allSiteEntries ? [ ], uplinkRouting ? { } }:

let
  inherit (helpers)
    hasAttr
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    sortedNames
    ;

  common = import ./Site/default-reachability/common.nix { inherit helpers; };
  inherit (common)
    accessNodeNameFromAdjacencyId
    attrsOrEmpty
    buildInternalDefaultRoute
    buildInternalEndpointRoute
    buildWANDefaultRoute
    defaultDst
    listContains
    listOrEmpty
    makeStringSet
    overlayNameFromInterfaceName
    routeAlreadyPresent
    routesContainDefault
    stripDefaultRoutes
    uniqueStrings
    uplinkNameFromAdjacencyId
    ;
  context = import ./Site/default-reachability/context.nix {
    inherit helpers common sitePath siteAttrs runtimeTargets allSiteEntries;
  };
  inherit (context)
    exitNodeSet
    forwardingSemantics
    forwardingSemanticsNodes
    runtimeTargetNames
    runtimeTargetsByNode
    overlayExitPeerSiteByName
    siteOverlayNameSet
    ;
  wanDefaults = import ./Site/default-reachability/wan-defaults.nix {
    inherit
      helpers
      common
      sitePath
      siteOverlayNameSet
      exitNodeSet
      runtimeTargets
      runtimeTargetNames
      uplinkRouting
      ;
  };
  inherit (wanDefaults)
    runtimeTargetsWithWANDefaults
    runtimeTargetsWithWANDefaultsByNode
    selectedUplinkNamesForTarget
    ;
  sourceSelection = import ./Site/default-reachability/source-selection.nix {
    inherit
      helpers
      common
      sitePath
      siteAttrs
      siteOverlayNameSet
      runtimeTargetsWithWANDefaultsByNode
      selectedUplinkNamesForTarget
      ;
  };
  inherit (sourceSelection)
    explicitDefaultSourceSet4
    explicitDefaultSourceSet6
    delegatedSourceUsesOverlayEgress
    isDelegatedIPv6AccessNode
    preferredFirstHopMatchesSource
    runtimeRoutedIPv6AccessNodeNames
    runtimeRoutedIPv6PrefixesByAccessNode
    targetHasDefaultReachabilityForFamily
    ;
  graph = import ./Site/default-reachability/graph.nix {
    inherit helpers common sitePath transit;
  };
  inherit (graph)
    sortedCandidatePaths
    transitEndpointAddressesByNode
    ;
  routeHelpers = import ./Site/default-reachability/route-helpers.nix {
    inherit helpers common sitePath;
  };
  inherit (routeHelpers)
    findInterfaceNameForAdjacency
    interfaceBackingKind
    interfaceHasDefaultForFamily
    interfaceNameHasUplinkWanPreference
    interfaceNameTargetsDestination
    ;

  ipam = import ./ipam.nix { inherit lib; };

  routeSynthesis = import ./Site/default-reachability/route-synthesis.nix {
    inherit
      helpers
      common
      ipam
      sitePath
      siteOverlayNameSet
      overlayExitPeerSiteByName
      runtimeTargetNames
      runtimeTargetsWithWANDefaults
      transitEndpointAddressesByNode
      sortedCandidatePaths
      preferredFirstHopMatchesSource
      explicitDefaultSourceSet4
      explicitDefaultSourceSet6
      delegatedSourceUsesOverlayEgress
      isDelegatedIPv6AccessNode
      runtimeRoutedIPv6AccessNodeNames
      runtimeRoutedIPv6PrefixesByAccessNode
      routeHelpers
      ;
  };
  inherit (routeSynthesis) runtimeTargetsWithSynthesizedDefaults;
  accessUplinkPrefixes = import ./Site/default-reachability/access-uplink-prefixes.nix {
    inherit
      lib
      helpers
      common
      sitePath
      runtimeTargetNames
      runtimeTargetsByNode
      runtimeTargetsWithSynthesizedDefaults
      ;
  };
  inherit (accessUplinkPrefixes) runtimeTargetsWithAccessUplinkPrefixes;
  authority = import ./Site/default-reachability/authority.nix {
    inherit
      helpers
      common
      sitePath
      forwardingSemantics
      forwardingSemanticsNodes
      runtimeTargetNames
      runtimeTargetsByNode
      targetHasDefaultReachabilityForFamily
      ;
    runtimeTargetsWithSynthesizedDefaults = runtimeTargetsWithAccessUplinkPrefixes;
  };
in
authority
