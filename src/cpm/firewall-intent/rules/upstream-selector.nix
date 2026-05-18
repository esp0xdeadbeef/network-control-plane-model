{ common }:

{
  endpointBindings ? { },
  transitInterfaces,
  relations ? [ ],
  services ? [ ],
}:

let
  endpointContext = import ./endpoint-context.nix { inherit common; } {
    inherit endpointBindings services transitInterfaces;
  };
  relationRules = import ./upstream-selector-relations.nix { inherit common endpointContext; };
  inherit (endpointContext) coreInterfaces policyInterfaces listOrEmpty;

  coreForPolicy = policyIface:
    let
      matchesCore =
        builtins.filter
          (coreIface: builtins.elem (common.laneUplink policyIface) (common.uplinks coreIface))
          coreInterfaces;
    in
    if matchesCore == [ ] then null else builtins.elemAt matchesCore 0;

  selectorPairRules =
    builtins.concatLists (
      map
        (policyIface:
          let coreIface = coreForPolicy policyIface;
          in if coreIface == null then [ ] else common.selectorPairRule policyIface coreIface)
        policyInterfaces
    );
in
selectorPairRules
++ builtins.concatLists (map relationRules.externalTransitRule (listOrEmpty relations))
++ builtins.concatLists (map relationRules.overlayUnderlayTransitRule (listOrEmpty relations))
++ builtins.concatLists (map relationRules.externalServiceTransitRule (listOrEmpty relations))
++ relationRules.runtimeRoutedPrefixPublicEgressRules
