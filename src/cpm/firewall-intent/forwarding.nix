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
  runtimeTargets ? { },
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

  isPublicResolver = forwarder:
    builtins.elem forwarder [
      "1.1.1.1"
      "1.0.0.1"
      "8.8.8.8"
      "8.8.4.4"
      "9.9.9.9"
      "2606:4700:4700::1111"
      "2606:4700:4700::1001"
      "2001:4860:4860::8888"
      "2001:4860:4860::8844"
      "2620:fe::fe"
    ];

  addressFamily = value:
    if builtins.isString value && builtins.match ".*:.*" value != null then 6 else 4;

  cleanAddress = value:
    if !(builtins.isString value) || value == "" || value == "127.0.0.1" || value == "::1" then
      null
    else
      value;

  publicDnsServiceSources =
    builtins.concatLists (
      map
        (targetName:
          let
            runtimeTarget = runtimeTargets.${targetName};
            dns = attrsOrEmpty ((attrsOrEmpty (runtimeTarget.services or null)).dns or null);
            forwarders =
              if builtins.isList (dns.forwarders or null) then
                dns.forwarders
              else
                listOrEmpty (dns.upstreams or null);
            publicForwarders = builtins.filter isPublicResolver forwarders;
            outgoing = listOrEmpty (dns.outgoingInterfaces or null);
            listeners = listOrEmpty (dns.listen or null);
            candidates = if outgoing != [ ] then outgoing else listeners;
          in
          if dns == { } || publicForwarders == [ ] then
            [ ]
          else
            map
              (address: {
                family = addressFamily address;
                prefix = address;
              })
              (builtins.filter (value: value != null) (map cleanAddress candidates)))
        (builtins.attrNames runtimeTargets)
    );

  dnsServicePublicEgressRules =
    builtins.concatLists (
      map
        (source:
          builtins.concatLists (
            map
              (transitIface:
                map
                  (uplinkIface: {
                    action = "accept";
                    intent = {
                      kind = "dns-service-public-egress";
                      source = "dns-service";
                    };
                    trafficType = "dns";
                    fromInterface = transitIface.runtimeIfName;
                    toInterface = uplinkIface.runtimeIfName;
                    sourcePrefixes = [ source ];
                    family = source.family;
                    comment = "allow-dns-service-egress";
                    applyTcpMssClamp = false;
                  })
                  uplinkInterfaces)
              transitInterfaces
          ))
        publicDnsServiceSources
    );
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
      inherit tenantPrefixOwners transitInterfaces uplinkInterfaces dnsServicePublicEgressRules;
    };
  }
else
  null
