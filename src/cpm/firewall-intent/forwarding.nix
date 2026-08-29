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
  sharedServicePolicyAtoms ? [ ],
  siteRelations,
  trafficPaths ? [ ],
  trafficTypeMatches ? { },
  target,
  interfaceRecords,
  tenantPrefixOwners ? { },
  runtimeOriginSourcePrefixes ? [ ],
  runtimeTargets ? { },
}:
let
  role = target.role or null;
  egressIntent = attrsOrEmpty (target.egressIntent or null);
  hasExplicitEgressIntent =
    (egressIntent.explicit or false) == true
    && (egressIntent ? exit || egressIntent ? eligible || egressIntent ? upstreamSelection);
  egressExitEnabled = !hasExplicitEgressIntent || (egressIntent.exit or false) == true;
  egressSelectorEnabled =
    !hasExplicitEgressIntent
    || (egressIntent.eligible or false) == true
    || (egressIntent.upstreamSelection or false) == true;
  selectedUplinks =
    listOrEmpty (egressIntent.uplinks or null) ++ listOrEmpty (egressIntent.wanInterfaces or null);
  backingRefName = iface: ((attrsOrEmpty (iface.backingRef or null)).name or null);
  selectedUplinkFor =
    iface:
    (!hasExplicitEgressIntent && selectedUplinks == [ ])
    || builtins.elem (iface.upstream or "") selectedUplinks
    || builtins.elem iface.sourceInterfaceName selectedUplinks
    || builtins.elem (backingRefName iface) selectedUplinks;
  localInterfaces = builtins.filter (iface: iface.sourceKind == "tenant") interfaceRecords;
  transitInterfaces = builtins.filter (
    iface: iface.sourceKind == "p2p" || iface.sourceKind == "pppoe-session"
  ) interfaceRecords;
  pppoeSessionInterfaces = builtins.filter (
    iface: iface.sourceKind == "pppoe-session"
  ) interfaceRecords;
  wanInterfaces = builtins.filter (iface: iface.sourceKind == "wan") interfaceRecords;
  lanInterfaces = builtins.filter (iface: iface.sourceKind == "tenant") interfaceRecords;
  uplinkInterfaces = builtins.filter (
    iface:
    egressExitEnabled
    && (
      (iface.sourceKind == "wan" && selectedUplinkFor iface)
      || (iface.sourceKind == "overlay" && selectedUplinkFor iface)
    )
  ) interfaceRecords;

  addressFamily =
    value: if builtins.isString value && builtins.match ".*:.*" value != null then 6 else 4;

  cleanAddress =
    value:
    if !(builtins.isString value) || value == "" || value == "127.0.0.1" || value == "::1" then
      null
    else
      value;

  publicDnsServiceSources = builtins.concatLists (
    map (
      targetName:
      let
        runtimeTarget = runtimeTargets.${targetName};
        dns = attrsOrEmpty ((attrsOrEmpty (runtimeTarget.services or null)).dns or null);
        forwarders =
          if builtins.isList (dns.forwarders or null) then
            dns.forwarders
          else
            listOrEmpty (dns.upstreams or null);
        publicForwarders = forwarders;
        runtimeOrigin = attrsOrEmpty (runtimeTarget.runtimeOriginEgress or null);
        modeledSourcePrefixes = listOrEmpty (runtimeOrigin.sourcePrefixes or null);
        recursionMode = dns.recursionMode or null;
        dnsEgress = attrsOrEmpty (dns.egress or null);
        dnsUplinks =
          if listOrEmpty (dnsEgress.uplinks or null) != [ ] then
            listOrEmpty dnsEgress.uplinks
          else
            listOrEmpty (runtimeOrigin.uplinks or null);
        outgoing = listOrEmpty (dns.outgoingInterfaces or null);
        listeners = listOrEmpty (dns.listen or null);
        candidates = if outgoing != [ ] then outgoing else listeners;
      in
      if dns == { } || (publicForwarders == [ ] && recursionMode != "iterative") then
        [ ]
      else if modeledSourcePrefixes != [ ] then
        map (source: source // { uplinks = dnsUplinks; }) modeledSourcePrefixes
      else
        map (address: {
          family = addressFamily address;
          prefix = address;
          uplinks = dnsUplinks;
        }) (builtins.filter (value: value != null) (map cleanAddress candidates))
    ) (builtins.attrNames runtimeTargets)
  );

  dnsSourceUsesUplink =
    source: iface:
    let
      allowed = listOrEmpty (source.uplinks or null);
      names = builtins.filter (value: value != null && value != "") [
        (iface.upstream or null)
        iface.sourceInterfaceName
        (backingRefName iface)
      ];
    in
    allowed == [ ] || builtins.any (name: builtins.elem name allowed) names;

  policyEndpointDiagnostics = attrsOrEmpty (
    (attrsOrEmpty policyEndpointBindings).diagnostics or null
  );
  unresolvedDenyDiagnostics = listOrEmpty (policyEndpointDiagnostics.unresolvedDenyEndpoints or null);
  policyDiagnosticAttrs =
    if unresolvedDenyDiagnostics == [ ] then
      { }
    else
      {
        diagnostics = {
          unresolvedDenyEndpoints = unresolvedDenyDiagnostics;
        };
      };

  dnsServicePublicEgressRules =
    let
      dnsMatches = trafficTypeMatches.dns or [ ];
    in
    builtins.concatLists (
      map (
        source:
        builtins.concatLists (
          map (
            transitIface:
            map (uplinkIface: {
              action = "accept";
              intent = {
                kind = "dns-service-public-egress";
                source = "dns-service";
              };
              trafficType = "dns";
              matches = dnsMatches;
              fromInterface = transitIface.runtimeIfName;
              toInterface = uplinkIface.runtimeIfName;
              sourcePrefixes = [ (builtins.removeAttrs source [ "uplinks" ]) ];
              family = source.family;
              comment = "allow-dns-service-egress";
              applyTcpMssClamp = false;
            }) (builtins.filter (dnsSourceUsesUplink source) uplinkInterfaces)
          ) transitInterfaces
        )
      ) publicDnsServiceSources
    );

  # FS-482: BGP control-plane traffic between the fabric router roles is
  # authorized only from the intent-declared `bgp` traffic type. Emit a
  # transit-to-transit accept on each fabric node for that traffic type so the
  # iBGP peering (loopback-to-loopback over the p2p fabric) is not dropped by
  # the deny-by-default forward chain.
  bgpControlPlaneRules =
    if (target.routingMode or "static") != "bgp" then
      [ ]
    else
      let
        bgpMatches = trafficTypeMatches.bgp or [ ];
        distinctTransitInterfaces = builtins.filter
          (iface: builtins.isString (iface.runtimeIfName or null) && iface.runtimeIfName != "")
          transitInterfaces;
      in
      builtins.concatLists (
        builtins.map
          (fromIface:
            builtins.concatLists (
              builtins.map
                (toIface:
                  if fromIface.runtimeIfName == toIface.runtimeIfName then
                    [ ]
                  else
                    builtins.map
                      (family: {
                        action = "accept";
                        intent = {
                          kind = "bgp-control-plane";
                          source = "routing";
                        };
                        trafficType = "bgp";
                        matches = bgpMatches;
                        fromInterface = fromIface.runtimeIfName;
                        toInterface = toIface.runtimeIfName;
                        sourcePrefixes = [ ];
                        inherit family;
                        comment = "allow-bgp-control-plane";
                        applyTcpMssClamp = false;
                      })
                      [ 4 6 ])
                distinctTransitInterfaces)
          )
          distinctTransitInterfaces
      );
in
if role == "access" then
  {
    mode = "explicit-access-forwarding";
    localInterfaces = map (iface: iface.runtimeIfName) (localInterfaces ++ pppoeSessionInterfaces);
    transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
    rules = buildAccessRules {
      targetLogicalNode = (attrsOrEmpty (target.logicalNode or null)).name or null;
      endpointBindings = attrsOrEmpty policyEndpointBindings;
      relations = siteRelations;
      inherit
        localInterfaces
        services
        trafficPaths
        trafficTypeMatches
        transitInterfaces
        runtimeOriginSourcePrefixes
        tenantPrefixOwners
        ;
    } ++ bgpControlPlaneRules;
  }
else if role == "downstream-selector" || role == "upstream-selector" then
  (
    {
      mode = "explicit-selector-forwarding";
      transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
      rules =
        (
          if role == "downstream-selector" then
            buildDownstreamSelectorRules {
              endpointBindings = attrsOrEmpty policyEndpointBindings;
              relations = siteRelations;
              inherit
                services
                trafficPaths
                trafficTypeMatches
                transitInterfaces
                runtimeOriginSourcePrefixes
                ;
            }
          else
            buildUpstreamSelectorRules {
              endpointBindings = attrsOrEmpty policyEndpointBindings;
              relations = siteRelations;
              egressEnabled = egressSelectorEnabled;
              inherit
                overlayNames
                services
                trafficTypeMatches
                transitInterfaces
                ;
              siteRuntimeOriginSourcePrefixes = runtimeOriginSourcePrefixes;
            }
        )
        ++ bgpControlPlaneRules;
    }
    // policyDiagnosticAttrs
  )
else if role == "policy" then
  (
    {
      mode = "explicit-policy-forwarding";
      transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
      rules = buildPolicyRules {
        endpointBindings = attrsOrEmpty policyEndpointBindings;
        relations = siteRelations;
        inherit
          services
          sharedServicePolicyAtoms
          trafficTypeMatches
          transitInterfaces
          runtimeOriginSourcePrefixes
          tenantPrefixOwners
          ;
      } ++ bgpControlPlaneRules;
    }
    // policyDiagnosticAttrs
  )
else if role == "core" then
  let
    coreRules = buildCoreRules {
      inherit
        tenantPrefixOwners
        transitInterfaces
        uplinkInterfaces
        dnsServicePublicEgressRules
        ;
    };
  in
  {
    mode = "explicit-core-forwarding";
    transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
    uplinkInterfaces = map (iface: iface.runtimeIfName) uplinkInterfaces;
    wanInterfaces = map (iface: iface.runtimeIfName) wanInterfaces;
    lanInterfaces = map (iface: iface.runtimeIfName) lanInterfaces;
    rules = coreRules.rules ++ bgpControlPlaneRules;
    # FS-270-HDS-010-SDS-010-SMS-010: fail-closed core-transit admission
    # record — denied surfaces are reported, never silently forwarded.
    transitAdmission = coreRules.transitAdmission;
  }
else
  null
