{ helpers }:

{ sitePath, siteAttrs, transit, runtimeTargets }:

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
    inherit helpers common sitePath siteAttrs runtimeTargets;
  };
  inherit (context)
    exitNodeSet
    forwardingSemantics
    forwardingSemanticsNodes
    runtimeTargetNames
    runtimeTargetsByNode
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
    isDelegatedIPv6AccessNode
    preferredFirstHopMatchesSource
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

  routeSynthesis = import ./Site/default-reachability/route-synthesis.nix {
    inherit
      helpers
      common
      sitePath
      siteOverlayNameSet
      runtimeTargetNames
      runtimeTargetsWithWANDefaults
      transitEndpointAddressesByNode
      sortedCandidatePaths
      preferredFirstHopMatchesSource
      explicitDefaultSourceSet4
      explicitDefaultSourceSet6
      isDelegatedIPv6AccessNode
      routeHelpers
      ;
  };
  inherit (routeSynthesis) runtimeTargetsWithSynthesizedDefaults;
  authority = import ./Site/default-reachability/authority.nix {
    inherit
      helpers
      common
      sitePath
      forwardingSemantics
      forwardingSemanticsNodes
      runtimeTargetNames
      runtimeTargetsByNode
      runtimeTargetsWithSynthesizedDefaults
      targetHasDefaultReachabilityForFamily
      ;
  };
in
authority
