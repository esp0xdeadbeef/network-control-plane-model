{ helpers
, common
,
}:

let
  inherit (helpers) hasAttr isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty failInventory listOrEmpty;

  boolOr = path: fallback: value:
    if value == null then
      fallback
    else if builtins.isBool value then
      value
    else
      failInventory path "must be a boolean";

  stringOr = path: fallback: value:
    if value == null then
      fallback
    else if isNonEmptyString value then
      value
    else
      failInventory path "must be a non-empty string";

  requiredBaseFields = [
    "upstreamType"
    "ipv4Mode"
    "ipv6Mode"
    "prefixAuthority"
    "dnsFollowSource"
    "publicIngress"
    "routeAuthority"
    "nat"
    "failureBehavior"
    "expectedClientEgress"
  ];

  hostOnly = family: address:
    isNonEmptyString address
    && builtins.match (if family == 4 then ".*/32" else ".*/128") address != null;
in
{
  classify = { overlayName, overlay }:
    let
      providerName = overlay.provider or null;
      authorityPath = "controlPlane.sites.*.*.overlays.${overlayName}.providerAuthority";
      authority = attrsOrEmpty (overlay.providerAuthority or null);
      publicIngress = attrsOrEmpty (authority.publicIngress or null);
      prefixAuthority = attrsOrEmpty (authority.prefixAuthority or null);
      dnsFollowSource = attrsOrEmpty (authority.dnsFollowSource or null);
      routeAuthority = attrsOrEmpty (authority.routeAuthority or null);
      nat = attrsOrEmpty (authority.nat or null);
      runtimeFacts = attrsOrEmpty (authority.runtimeFacts or null);
      commercialVpn = attrsOrEmpty (authority.commercialVpn or null);
      ipam = attrsOrEmpty (overlay.ipam or null);
      ipam4 = attrsOrEmpty (ipam.ipv4 or null);
      ipam6 = attrsOrEmpty (ipam.ipv6 or null);
      nodes = attrsOrEmpty (overlay.nodes or null);

      missingBaseFields =
        builtins.filter (field: !(hasAttr field authority)) requiredBaseFields;

      upstreamType =
        stringOr "${authorityPath}.upstreamType" providerName (authority.upstreamType or null);
      providerTechnology =
        stringOr "${authorityPath}.providerTechnology" providerName (authority.providerTechnology or null);
      isCommercialVpn =
        providerName == "commercial-vpn"
        || upstreamType == "commercial-vpn"
        || (authority.profileClass or null) == "commercial-vpn";

      publicIngressAllowed =
        boolOr "${authorityPath}.publicIngress.allowed" false (publicIngress.allowed or null);
      routedClientAllowed =
        boolOr "${authorityPath}.prefixAuthority.routedClient" false (prefixAuthority.routedClient or null);
      delegatedClientAllowed =
        boolOr "${authorityPath}.prefixAuthority.delegated" false (prefixAuthority.delegated or null);
      translatedClientAllowed =
        boolOr "${authorityPath}.prefixAuthority.translated" false (prefixAuthority.translated or null);

      runtimeCreatesPolicy =
        boolOr "${authorityPath}.runtimeFacts.createsPolicyAuthority" false (runtimeFacts.createsPolicyAuthority or null);
      runtimeCreatesPrefix =
        boolOr "${authorityPath}.runtimeFacts.createsPrefixAuthority" false (runtimeFacts.createsPrefixAuthority or null);
      _runtimeAuthority =
        if runtimeCreatesPolicy || runtimeCreatesPrefix then
          failInventory "${authorityPath}.runtimeFacts" "runtime facts must not create provider policy or prefix authority"
        else
          true;

      commercialPublicFromPresence =
        boolOr "${authorityPath}.commercialVpn.publicIngressFromPresence" false (commercialVpn.publicIngressFromPresence or null);
      commercialRoutedFromPresence =
        boolOr "${authorityPath}.commercialVpn.routedClientPrefixFromPresence" false (commercialVpn.routedClientPrefixFromPresence or null);
      _commercialPresence =
        if isCommercialVpn && (commercialPublicFromPresence || commercialRoutedFromPresence) then
          failInventory "${authorityPath}.commercialVpn" "commercial VPN profile presence must not grant public ingress or routed client-prefix authority"
        else
          true;

      # SMS-010: Reject commercial VPN with publicIngress.allowed=true (unauthorized authority claim)
      _commercialPublicIngress =
        if isCommercialVpn && publicIngressAllowed then
          failInventory "${authorityPath}.publicIngress.allowed" "commercial VPN must not claim public ingress authority (portable-egress only)"
        else
          true;

      # SMS-010: Reject ipv4Mode/natMode conflict
      ipv4Mode =
        stringOr "${authorityPath}.ipv4Mode"
          (if ipam4 != { } then "overlay-node-host-only" else "unspecified")
          (authority.ipv4Mode or null);
      ipv6Mode =
        stringOr "${authorityPath}.ipv6Mode"
          (if ipam6 != { } then "overlay-node-host-only" else "unspecified")
          (authority.ipv6Mode or null);
      nat44 =
        stringOr "${authorityPath}.nat.nat44" "none" (nat.nat44 or null);

      _ipv4NatConflict =
        if ipv4Mode == "routed-public" && nat44 != "none" then
          failInventory "${authorityPath}" "provider-ipv4-nat-conflict: routed-public ipv4Mode with nat44=${nat44} requires nat44=none"
        else
          true;

      nodeEndpointRecords =
        builtins.concatLists (
          builtins.map
            (nodeName:
              let
                node = nodes.${nodeName};
                addr4 = node.addr4 or null;
                addr6 = node.addr6 or null;
              in
              (if isNonEmptyString addr4 then [
                {
                  family = 4;
                  node = nodeName;
                  address = addr4;
                  classification = if hostOnly 4 addr4 then "host-only-provider-endpoint" else "provider-endpoint";
                  hostOnly = hostOnly 4 addr4;
                  clientPrefixAuthority = false;
                }
              ] else [ ])
              ++ (if isNonEmptyString addr6 then [
                {
                  family = 6;
                  node = nodeName;
                  address = addr6;
                  classification = if hostOnly 6 addr6 then "host-only-provider-endpoint" else "provider-endpoint";
                  hostOnly = hostOnly 6 addr6;
                  clientPrefixAuthority = false;
                }
              ] else [ ]))
            (sortedNames nodes)
        );

      runtimeFactRecord =
        if runtimeFacts == { } then
          null
        else
          {
            kind = "provider-runtime-facts";
            source = "providerAuthority.runtimeFacts";
            facts = builtins.removeAttrs runtimeFacts [
              "createsPolicyAuthority"
              "createsPrefixAuthority"
            ];
            authority = {
              createsPolicyAuthority = false;
              createsPrefixAuthority = false;
              runtimeAuthority = false;
            };
          };
    in
    builtins.seq _runtimeAuthority (
      builtins.seq _commercialPresence (
        builtins.seq _commercialPublicIngress (
          builtins.seq _ipv4NatConflict {
        rowIds = [
          "FS-440-HDS-010-SDS-010-SMS-010"
          "FS-440-HDS-010-SDS-010-SMS-020"
          "FS-440-HDS-010-SDS-010-SMS-030"
          "FS-440-HDS-010-SDS-010-SMS-040"
          "FS-440-HDS-010-SDS-010-SMS-050"
        ];
        emittedRecord = {
          kind = "provider-authority-classification";
          stage = "control-plane-model";
          provider = providerName;
          overlay = overlayName;
        };
        consumedInterfaces = {
          providerDeclaration = "controlPlane.sites.*.*.overlays.${overlayName}.provider";
          providerAuthority = "${authorityPath}";
          overlayIdentity = "forwardingModel.enterprise.*.site.*.transport.overlays.${overlayName}";
          overlayNodeIpam = "forwardingModel.enterprise.*.site.*.pools.overlay plus ${authorityPath}.nodes";
          runtimeFacts = "${authorityPath}.runtimeFacts";
        };
        baseClassification = {
          inherit upstreamType ipv4Mode ipv6Mode;
          prefixAuthority = {
            routedClient = routedClientAllowed;
            delegated = delegatedClientAllowed;
            translated = translatedClientAllowed;
            source = stringOr "${authorityPath}.prefixAuthority.source" "provider-authority-record" (prefixAuthority.source or null);
          };
          dnsFollowSource = {
            enabled = boolOr "${authorityPath}.dnsFollowSource.enabled" false (dnsFollowSource.enabled or null);
            source = stringOr "${authorityPath}.dnsFollowSource.source" "provider-authority-record" (dnsFollowSource.source or null);
          };
          publicIngress = {
            allowed = publicIngressAllowed;
            source = stringOr "${authorityPath}.publicIngress.source" "provider-authority-record" (publicIngress.source or null);
          };
          routeAuthority = {
            import = boolOr "${authorityPath}.routeAuthority.import" false (routeAuthority.import or null);
            export = boolOr "${authorityPath}.routeAuthority.export" false (routeAuthority.export or null);
            source = stringOr "${authorityPath}.routeAuthority.source" "provider-authority-record" (routeAuthority.source or null);
          };
          nat = {
            inherit nat44;
            nat66 = stringOr "${authorityPath}.nat.nat66" "none" (nat.nat66 or null);
          };
          failureBehavior =
            stringOr "${authorityPath}.failureBehavior" "fail-closed" (authority.failureBehavior or null);
          expectedClientEgress =
            stringOr "${authorityPath}.expectedClientEgress"
              (if isCommercialVpn then "portable-egress" else "provider-egress")
              (authority.expectedClientEgress or null);
          complete = missingBaseFields == [ ];
          behaviorEmissionAllowed = missingBaseFields == [ ];
        };
        overlayClassification = {
          overlayIdentity = overlayName;
          inherit providerTechnology;
          overlayNodeIpamAuthority = {
            ipv4 = ipam4;
            ipv6 = ipam6;
            nodes = nodes;
          };
          clientPrefixAuthority = {
            routed = routedClientAllowed;
            delegated = delegatedClientAllowed;
            translated = translatedClientAllowed;
            fromEndpointFacts = false;
          };
          wanEgressRelationship =
            stringOr "${authorityPath}.wanEgressRelationship"
              "policy-selected-provider-egress"
              (authority.wanEgressRelationship or null);
        };
        endpointClassification = {
          records = nodeEndpointRecords;
          invalidEndpointPromotion = false;
        };
        commercialVpnClassification = {
          applies = isCommercialVpn;
          default = if isCommercialVpn then "portable-egress" else "not-commercial-vpn";
          publicIngressAllowed = publicIngressAllowed;
          routedClientPrefixAllowed = routedClientAllowed;
          grantsAuthorityFromPresence = false;
        };
        runtimeFactSeparation = {
          records = if runtimeFactRecord == null then [ ] else [ runtimeFactRecord ];
          diagnostic = {
            code = "provider-runtime-facts-not-authority";
            mode = "fail-closed";
            runtimeAuthority = false;
            policyAuthority = false;
            prefixAuthority = false;
            authoritySource = "modeled-provider-authority";
          };
        };
        diagnostics = {
          baseClassification =
            if missingBaseFields == [ ] then
              [ ]
            else
              [
                {
                  code = "provider-classification-incomplete";
                  mode = "fail-closed";
                  missingFields = missingBaseFields;
                  behaviorEmissionAllowed = false;
                }
              ];
          runtimeAuthority = [
            {
              code = "provider-runtime-facts-not-authority";
              mode = "fail-closed";
              runtimeAuthority = false;
              policyAuthority = false;
              prefixAuthority = false;
            }
          ];
          commercialVpn =
            if isCommercialVpn then
              [
                {
                  code = "commercial-vpn-portable-egress-default";
                  mode = "fail-closed";
                  publicIngressAllowed = publicIngressAllowed;
                  routedClientPrefixAllowed = routedClientAllowed;
                  grantsAuthorityFromPresence = false;
                }
              ]
            else
              [ ];
        };
      }
      )
      )
    );
}
