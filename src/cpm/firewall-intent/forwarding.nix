{ helpers }:

let
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];
  ruleBuilders = import ./rules.nix { };
  inherit (ruleBuilders)
    buildAccessRules
    buildCoreRules
    buildDownstreamSelectorRules
    buildPolicyRules
    buildUpstreamSelectorRules
    ;
in
{
  overlayNames ? [ ],
  policyEndpointBindings,
  services,
  siteRelations,
  target,
  interfaceRecords,
  tenantPrefixOwners ? { },
  runtimeOriginSourcePrefixes ? [ ],
}:
let
  role = target.role or null;
  egressIntent = attrsOrEmpty (target.egressIntent or null);
  selectedUplinks =
    listOrEmpty (egressIntent.uplinks or null) ++ listOrEmpty (egressIntent.wanInterfaces or null);
  backingRefName = iface: ((attrsOrEmpty (iface.backingRef or null)).name or null);
  selectedUplinkFor =
    iface:
    selectedUplinks == [ ]
    || builtins.elem (iface.upstream or "") selectedUplinks
    || builtins.elem iface.sourceInterfaceName selectedUplinks
    || builtins.elem (backingRefName iface) selectedUplinks;
  localInterfaces = builtins.filter (iface: iface.sourceKind == "tenant") interfaceRecords;
  transitInterfaces = builtins.filter (iface: iface.sourceKind == "p2p") interfaceRecords;
  uplinkInterfaces = builtins.filter (
    iface:
    (iface.sourceKind == "wan" && selectedUplinkFor iface)
    || (iface.sourceKind == "overlay" && selectedUplinks != [ ] && selectedUplinkFor iface)
  ) interfaceRecords;
in
if role == "access" then
  {
    mode = "explicit-access-forwarding";
    localInterfaces = map (iface: iface.runtimeIfName) localInterfaces;
    transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
    rules = buildAccessRules {
      inherit localInterfaces transitInterfaces runtimeOriginSourcePrefixes;
    };
  }
else if role == "downstream-selector" || role == "upstream-selector" then
  {
    mode = "explicit-selector-forwarding";
    transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
    rules =
      if role == "downstream-selector" then
        buildDownstreamSelectorRules {
          endpointBindings = attrsOrEmpty policyEndpointBindings;
          relations = siteRelations;
          inherit services transitInterfaces runtimeOriginSourcePrefixes;
        }
      else
        buildUpstreamSelectorRules {
          endpointBindings = attrsOrEmpty policyEndpointBindings;
          relations = siteRelations;
          inherit overlayNames services transitInterfaces;
          siteRuntimeOriginSourcePrefixes = runtimeOriginSourcePrefixes;
        };
  }
else if role == "policy" then
  {
    mode = "explicit-policy-forwarding";
    transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
    rules = buildPolicyRules {
      endpointBindings = attrsOrEmpty policyEndpointBindings;
      relations = siteRelations;
      inherit services transitInterfaces runtimeOriginSourcePrefixes;
    };
  }
else if role == "core" then
  {
    mode = "explicit-core-forwarding";
    transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
    uplinkInterfaces = map (iface: iface.runtimeIfName) uplinkInterfaces;
    rules = buildCoreRules {
      inherit tenantPrefixOwners transitInterfaces uplinkInterfaces;
    };
  }
else
  null
