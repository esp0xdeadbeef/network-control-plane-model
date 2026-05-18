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
{ policyEndpointBindings, services, siteRelations, target, interfaceRecords }:
let
  role = target.role or null;
  egressIntent = attrsOrEmpty (target.egressIntent or null);
  localInterfaces = builtins.filter (iface: iface.sourceKind == "tenant") interfaceRecords;
  transitInterfaces = builtins.filter (iface: iface.sourceKind == "p2p") interfaceRecords;
  uplinkInterfaces =
    builtins.filter
      (iface:
        iface.sourceKind == "wan"
        && (!builtins.isList (egressIntent.uplinks or null)
          || egressIntent.uplinks == [ ]
          || builtins.elem (iface.upstream or "") (listOrEmpty (egressIntent.uplinks or null))
          || builtins.elem iface.sourceInterfaceName (listOrEmpty (egressIntent.wanInterfaces or null))))
      interfaceRecords;
in
if role == "access" then
  {
    mode = "explicit-access-forwarding";
    localInterfaces = map (iface: iface.runtimeIfName) localInterfaces;
    transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
    rules = buildAccessRules localInterfaces transitInterfaces;
  }
else if role == "downstream-selector" || role == "upstream-selector" then
  {
    mode = "explicit-selector-forwarding";
    transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
    rules =
      if role == "downstream-selector" then
        buildDownstreamSelectorRules transitInterfaces
      else
        buildUpstreamSelectorRules {
          endpointBindings = attrsOrEmpty policyEndpointBindings;
          relations = siteRelations;
          inherit services transitInterfaces;
        };
  }
else if role == "policy" then
  {
    mode = "explicit-policy-forwarding";
    transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
    rules = buildPolicyRules {
      endpointBindings = attrsOrEmpty policyEndpointBindings;
      relations = siteRelations;
      inherit services transitInterfaces;
    };
  }
else if role == "core" then
  {
    mode = "explicit-core-forwarding";
    transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
    uplinkInterfaces = map (iface: iface.runtimeIfName) uplinkInterfaces;
    rules = buildCoreRules transitInterfaces uplinkInterfaces;
  }
else
  null
