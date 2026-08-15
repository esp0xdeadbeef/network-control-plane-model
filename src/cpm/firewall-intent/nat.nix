{ helpers, lib, ipam }:

let
  inherit (helpers) isNonEmptyString;
  natHelpers = import ./nat-helpers.nix { inherit helpers; };
  natEgressAuthority = import ./nat-egress-authority.nix { inherit helpers natHelpers; };
  inherit (natHelpers)
    attrsOrEmpty
    hasHostIPv4
    hasHostIPv6
    interfaceDeclined
    interfaceMatchesIdentity
    isIpv4Prefix
    isPrivate4Prefix
    isUla6Prefix
    listOrEmpty
    prefixValue
    uniqueStrings
    ;
in
{ siteAttrs
, overlayNames
, services ? [ ]
, policyEndpointBindings ? { }
, interfaceRecords
, target
, targetName ? ""
, runtimeOriginSourcePrefixes ? [ ]
, routedPrefixesByTenant ? { }
,
}:
let
  buildPublicIngress = import ./public-ingress.nix { inherit helpers lib ipam; };
  publicIngress = buildPublicIngress {
    inherit
      interfaceRecords
      policyEndpointBindings
      services
      siteAttrs
      target
      targetName
      routedPrefixesByTenant
      ;
  };
  publicIngressNatEnabled = builtins.any (record: record.destinationTranslation) publicIngress;
  siteTenantPrefixes = listOrEmpty ((attrsOrEmpty (siteAttrs.domains or null)).tenants or null);
  siteOwnershipPrefixes = listOrEmpty ((attrsOrEmpty (siteAttrs.ownership or null)).prefixes or null);
  internetTenantNames = uniqueStrings (
    builtins.map (rel: (attrsOrEmpty (rel.from or null)).name or "") (
      builtins.filter (rel:
        ((attrsOrEmpty (rel.from or null)).kind or null) == "tenant"
        && ((attrsOrEmpty (rel.to or null)).kind or null) == "external"
        && (((attrsOrEmpty (rel.to or null)).name or null) == "wan" || ((attrsOrEmpty (rel.to or null)).uplinks or []) != [ ])
        && (rel.action or "allow") == "allow")
      (listOrEmpty ((attrsOrEmpty (siteAttrs.communicationContract or null)).relations or null))
    )
  );
  siteNat44SourcePrefixes =
    builtins.map prefixValue (
      builtins.filter isPrivate4Prefix (
        builtins.filter (p: p != "") (
          (builtins.map (tenant: if builtins.isAttrs tenant then (if builtins.elem (tenant.name or "") internetTenantNames then tenant.ipv4 or "" else "") else tenant) siteTenantPrefixes)
          ++ (builtins.map (prefix: if builtins.isAttrs prefix then (if builtins.elem (prefix.name or "") internetTenantNames then prefix.ipv4 or prefix.prefix or "" else "") else prefix) siteOwnershipPrefixes)
        )
      )
    );
  runtimeOriginNat44SourcePrefixes =
    builtins.map prefixValue (builtins.filter isIpv4Prefix (listOrEmpty runtimeOriginSourcePrefixes));
  runtimeOriginNat66SourcePrefixes =
    builtins.map prefixValue (builtins.filter isUla6Prefix (listOrEmpty runtimeOriginSourcePrefixes));
  egressIntent = attrsOrEmpty (target.egressIntent or null);
  exitEnabled = (egressIntent.exit or false) == true;
  coreOriginUplinkDefaultAllowed = (egressIntent.coreOriginUplinkDefaultAllowed or false) == true;
  selectedUplinks = uniqueStrings (
    listOrEmpty (egressIntent.uplinks or null) ++ listOrEmpty (egressIntent.wanInterfaces or null)
  );
  declinedInterfaceIdentities = uniqueStrings (
    listOrEmpty (egressIntent.declinedInterfaces or null)
    ++ listOrEmpty (egressIntent.interfaceDeclineList or null)
    ++ listOrEmpty (egressIntent.declineInterfaces or null)
  );
  declined = interfaceDeclined declinedInterfaceIdentities;
  nat44ByUplink = attrsOrEmpty (egressIntent.nat44 or null);
  nat44SelectedIntents = map (uplink: attrsOrEmpty (nat44ByUplink.${uplink} or null)) selectedUplinks;
  nonInternetTenantPrefixes4 = uniqueStrings (
    builtins.filter isPrivate4Prefix (
      builtins.filter (p: p != "") (
        (builtins.map (tenant: if builtins.isAttrs tenant then (if builtins.elem (tenant.name or "") internetTenantNames then "" else tenant.ipv4 or "") else "") siteTenantPrefixes)
        ++ (builtins.map (prefix: if builtins.isAttrs prefix then (if builtins.elem (prefix.name or "") internetTenantNames then "" else prefix.ipv4 or prefix.prefix or "") else "") siteOwnershipPrefixes)
      )
    )
  );
  nat44SourcePrefixes = uniqueStrings (
    builtins.filter (prefix: !(builtins.elem prefix nonInternetTenantPrefixes4)) (
      builtins.concatMap (intent: listOrEmpty (intent.sourcePrefixes or null)) nat44SelectedIntents
      ++ siteNat44SourcePrefixes
      ++ runtimeOriginNat44SourcePrefixes
      ++ masqueradeFabricPrefixes4
    )
  );
  nat66ByUplink = attrsOrEmpty (egressIntent.nat66 or null);
  nat66SelectedIntents = map (uplink: attrsOrEmpty (nat66ByUplink.${uplink} or null)) selectedUplinks;
  nat66Requested = builtins.any (intent: (intent.mode or null) == "nat66") nat66SelectedIntents;
  trafficClass = egressIntent.trafficClass or "internet-egress";
  nat66SourcePrefixes = uniqueStrings (
    builtins.concatMap (intent: listOrEmpty (intent.sourcePrefixes or null)) nat66SelectedIntents
    ++ runtimeOriginNat66SourcePrefixes
    ++ masqueradeFabricPrefixes6
  );
  nat66Authority = natEgressAuthority { inherit interfaceRecords nat66ByUplink; };
  inherit (nat66Authority) explicitNat66Interfaces explicitNat66RuntimeNames hasNat66EgressAuthority;
  nat66Warning =
    let
      warnings = uniqueStrings (
        builtins.concatMap
          (
            intent: if isNonEmptyString (intent.warning or null) then [ intent.warning ] else [ ]
          )
          nat66SelectedIntents
      );
    in
    warnings;
  transitInterfaces = builtins.filter (iface: iface.sourceKind == "p2p") interfaceRecords;
  # === SMS-100: CPM NAT fabric prefix inclusion ===
  # Fabric-internal interfaces: non-WAN, non-overlay, non-declined
  # These are p2p and tenant interfaces whose addresses need masquerading
  # when they source traffic through a NAT-eligible core.
  fabricSourceInterfaces = builtins.filter
    (iface:
      iface.sourceKind != "wan"
      && iface.sourceKind != "overlay"
      && !(declined iface)
    )
    interfaceRecords;
  routeList =
    family: iface:
    let
      routes = attrsOrEmpty (iface.routes or null);
    in
    if builtins.isList (routes.${family} or null) then routes.${family} else [ ];
  isRoutedFabricPrefix4 =
    route:
    let
      dst = if builtins.isAttrs route then route.dst or "" else "";
    in
    dst != "0.0.0.0/0"
    && builtins.match ".*/32$" dst == null
    && isPrivate4Prefix dst;
  isRoutedFabricPrefix6 =
    route:
    let
      dst = if builtins.isAttrs route then route.dst or "" else "";
    in
    dst != "::/0"
    && builtins.match ".*/128$" dst == null
    && isUla6Prefix dst;
  routedFabricPrefixes4 = uniqueStrings (
    map (route: route.dst) (
      builtins.filter isRoutedFabricPrefix4 (
        builtins.concatMap (routeList "ipv4") fabricSourceInterfaces
      )
    )
  );
  routedFabricPrefixes6 = uniqueStrings (
    map (route: route.dst) (
      builtins.filter isRoutedFabricPrefix6 (
        builtins.concatMap (routeList "ipv6") fabricSourceInterfaces
      )
    )
  );
  # Derive subnet prefixes from addr4, excluding /32 host routes
  masqueradeFabricPrefixes4 = uniqueStrings (
    routedFabricPrefixes4 ++ builtins.filter (prefix: prefix != "" && builtins.match ".*/32$" prefix == null) (
      map (iface: let a = iface.addr4 or null; in if builtins.isString a then a else "") fabricSourceInterfaces
    )
  );
  # Derive subnet prefixes from addr6, excluding /128 host routes
  masqueradeFabricPrefixes6 = uniqueStrings (
    routedFabricPrefixes6 ++ builtins.filter (prefix: prefix != "" && builtins.match ".*/128$" prefix == null) (
      map (iface: let a = iface.addr6 or null; in if builtins.isString a then a else "") fabricSourceInterfaces
    )
  );
  # === end SMS-100 ===
  physicalWanInterfaces = builtins.filter
    (
      iface:
      iface.sourceKind == "wan"
      && !(builtins.elem (iface.upstream or "") overlayNames)
    )
    interfaceRecords;
  selectedPhysicalUplinks =
    builtins.filter (uplink: !(builtins.elem uplink overlayNames)) selectedUplinks;
  selectedWanInterfaces =
    builtins.filter
      (
        iface:
        selectedUplinks == [ ]
        || builtins.any (uplink: interfaceMatchesIdentity uplink iface) selectedUplinks
      )
      physicalWanInterfaces;
  missingSelectedUplinks =
    builtins.filter
      (uplink: !(builtins.any (iface: interfaceMatchesIdentity uplink iface) physicalWanInterfaces))
      selectedPhysicalUplinks;
  declinedSelectedUplinks =
    builtins.filter
      (
        uplink:
	        builtins.any (iface: interfaceMatchesIdentity uplink iface && declined iface) physicalWanInterfaces
	        && !(builtins.any (iface: interfaceMatchesIdentity uplink iface && !(declined iface)) physicalWanInterfaces)
      )
      selectedPhysicalUplinks;
  selectedWanInterfacesChecked =
    if exitEnabled && missingSelectedUplinks != [ ] then
      throw "egressIntent selected uplink(s) not realized as WAN interface before renderer projection: ${builtins.concatStringsSep ", " missingSelectedUplinks}"
    else if exitEnabled && declinedSelectedUplinks != [ ] then
      throw "egressIntent selected uplink(s) resolve only to declined interface identities before renderer projection: ${builtins.concatStringsSep ", " declinedSelectedUplinks}; declined identities: ${builtins.concatStringsSep ", " declinedInterfaceIdentities}"
    else
      selectedWanInterfaces;
  wanInterfaces = builtins.filter (iface: !(declined iface)) selectedWanInterfacesChecked;
  nat4Enabled = exitEnabled && builtins.any hasHostIPv4 wanInterfaces;
  nat6Enabled =
    exitEnabled
    && explicitNat66Interfaces != [ ]
    && nat66SourcePrefixes != [ ]
    && builtins.any hasNat66EgressAuthority wanInterfaces;
  natEnabled = nat4Enabled || nat6Enabled;
  wanRuntimeNames = map (iface: iface.runtimeIfName) wanInterfaces;
  nat44RuntimeNames =
    map (iface: iface.runtimeIfName) (builtins.filter hasHostIPv4 wanInterfaces);
  nat66RuntimeNames =
    map (iface: iface.runtimeIfName)
      (
        builtins.filter
          (
            iface: hasNat66EgressAuthority iface && builtins.elem iface.runtimeIfName explicitNat66RuntimeNames
          )
          wanInterfaces
      );
  translatedPrefixesForInterface =
    iface:
    let
      wan = attrsOrEmpty (iface.wan or null);
      egress = attrsOrEmpty (wan.egress or null);
      ipv6 = attrsOrEmpty (egress.ipv6 or null);
      translation = attrsOrEmpty (ipv6.translation or null);
    in
    listOrEmpty (translation.translatedPrefixes or null)
    ++ listOrEmpty (translation.translatedAddressOrPrefix or null)
    ++ listOrEmpty (translation.translatedAddresses or null)
    ++ [
      (translation.translatedPrefix or "")
      (translation.translatedAddress or "")
      (translation.prefix or "")
      (translation.address or "")
    ];
  nat66TranslatedAddressOrPrefix = uniqueStrings (builtins.concatMap translatedPrefixesForInterface explicitNat66Interfaces);
  translatedAddressesForInterface =
    iface:
    let
      explicitAddress = (attrsOrEmpty (iface.ipv4 or null)).address or null;
      hostUplinkAddress = (attrsOrEmpty ((attrsOrEmpty (iface.hostUplink or null)).ipv4 or null)).address or null;
      addr4 = iface.addr4 or null;
    in
    uniqueStrings (
      builtins.filter isNonEmptyString [
        addr4
        explicitAddress
        hostUplinkAddress
      ]
    );
  nat44TranslatedAddressOrPrefix =
    uniqueStrings (
      builtins.concatMap translatedAddressesForInterface (
        builtins.filter hasHostIPv4 wanInterfaces
      )
    );
  tenantNames = uniqueStrings (
    map (tenant: if builtins.isAttrs tenant then tenant.name or "" else "") (
      listOrEmpty ((attrsOrEmpty (siteAttrs.domains or null)).tenants or null)
    )
  );
  returnBehaviorFor = familyEnabled: {
    broadCoreOriginUplinkDefault =
      if coreOriginUplinkDefaultAllowed then "explicitly-allowed" else "blackholed";
    sourceScopedException = familyEnabled;
  };
  translationRecords =
    (if nat4Enabled then
      [
        {
          family = 4;
          mode = "nat44";
          trafficClass = trafficClass;
          sourceScope = nat44SourcePrefixes;
          translatedAddressOrPrefix = nat44TranslatedAddressOrPrefix;
          translatedAddressOrPrefixState =
            if nat44TranslatedAddressOrPrefix == [ ] then "runtime-egress-interface-address" else "explicit";
          egressSurface = {
            selectedUplinks = selectedUplinks;
            selectedUplinkInterfaces = nat44RuntimeNames;
          };
          tenantIsolationBoundary = {
            kind = "tenant-source-prefix";
            tenants = tenantNames;
            sourcePrefixes = nat44SourcePrefixes;
          };
          returnBehavior = returnBehaviorFor nat4Enabled;
          consumers = [ "routing" "firewall" "renderer" "diagnostic" ];
        }
      ]
    else
      [ ])
    ++ (if nat6Enabled then
      [
        {
          family = 6;
          mode = "nat66";
          trafficClass = trafficClass;
          sourceScope = nat66SourcePrefixes;
          translatedAddressOrPrefix = nat66TranslatedAddressOrPrefix;
          translatedAddressOrPrefixState =
            if nat66TranslatedAddressOrPrefix == [ ] then "unavailable" else "explicit";
          egressSurface = {
            selectedUplinks = selectedUplinks;
            selectedUplinkInterfaces = nat66RuntimeNames;
          };
          tenantIsolationBoundary = {
            kind = "tenant-source-prefix";
            tenants = tenantNames;
            sourcePrefixes = nat66SourcePrefixes;
          };
          returnBehavior = returnBehaviorFor nat6Enabled;
          consumers = [ "routing" "firewall" "renderer" "diagnostic" ];
        }
      ]
    else
      [ ]);
  nat66FailureDiagnostic =
    { code
    , message
    , sourceScope ? nat66SourcePrefixes
    , extra ? { }
    ,
    }:
    {
      inherit code message trafficClass;
      mode = "fail-closed";
      failClosed = true;
      sourceScope = sourceScope;
      egressSurface = {
        selectedUplinks = selectedUplinks;
        selectedUplinkInterfaces = wanRuntimeNames;
      };
      translatedAddressOrPrefix = nat66TranslatedAddressOrPrefix;
      translatedAddressOrPrefixState =
        if nat66TranslatedAddressOrPrefix == [ ] then "unavailable" else "modeled-but-unusable";
      addressFamily = 6;
      tenantIsolationBoundary = {
        kind = "tenant-source-prefix";
        tenants = tenantNames;
        sourcePrefixes = sourceScope;
      };
      fallback = {
        unmodeledEgress = false;
        untranslatedUlaRoute = false;
        alternateProviders = false;
      };
    } // extra;
  nat66Diagnostics =
    if !exitEnabled || nat6Enabled then
      [ ]
    else if !nat66Requested then
      if runtimeOriginNat66SourcePrefixes == [ ] then
        [ ]
      else
        [
          (nat66FailureDiagnostic {
            code = "nat66-explicit-selection-required";
            message = "ULA-to-WAN egress is denied unless NAT66 is explicitly selected.";
            sourceScope = runtimeOriginNat66SourcePrefixes;
            extra = {
              selectedUplinks = selectedUplinks;
              selectedUplinkInterfaces = wanRuntimeNames;
            };
          })
        ]
    else if nat66SourcePrefixes == [ ] then
      [
        (nat66FailureDiagnostic {
          code = "nat66-source-prefix-unavailable";
          message = "ULA NAT66 was selected without any ULA source-prefix binding.";
          extra = {
            selectedUplinks = selectedUplinks;
          };
        })
      ]
    else if explicitNat66Interfaces == [ ] then
      [
        (nat66FailureDiagnostic {
          code = "nat66-egress-unavailable";
          message = "ULA NAT66 was selected without any matching WAN NAT66 translation egress space.";
          extra = {
            selectedUplinks = selectedUplinks;
            selectedUplinkInterfaces = wanRuntimeNames;
          };
        })
      ]
    else if nat66RuntimeNames == [ ] then
      [
        (nat66FailureDiagnostic {
          code = "nat66-egress-unavailable";
          message = "ULA NAT66 was selected but no selected WAN interface has both NAT66 translation mode and IPv6 egress authority.";
          extra = {
            selectedUplinks = selectedUplinks;
            selectedUplinkInterfaces = wanRuntimeNames;
            nat66TranslationInterfaces = explicitNat66RuntimeNames;
          };
        })
      ]
    else
      [ ];
  coreUplinkRouteSafety = natHelpers.routeSafety {
    inherit
      coreOriginUplinkDefaultAllowed
      declinedInterfaceIdentities
      exitEnabled
      nat44RuntimeNames
      nat44SourcePrefixes
      nat4Enabled
      nat66RuntimeNames
      nat66SourcePrefixes
      nat6Enabled
      natEnabled
      selectedUplinks
      target
      wanRuntimeNames
      ;
  };
  # === hostNat contract block (SMS-020 / SMS-040) ===
  hostNat =
    let
      nat4WanInterfaces = builtins.filter hasHostIPv4 wanInterfaces;
      firstWan = if nat4WanInterfaces != [ ] then builtins.head nat4WanInterfaces else null;
      hostUplink = if firstWan != null then attrsOrEmpty (firstWan.hostUplink or null) else { };
      bridgeName = if isNonEmptyString (hostUplink.bridge or null) then hostUplink.bridge else null;
      attach = if firstWan != null then attrsOrEmpty (firstWan.attach or null) else { };
      vlanValue = if builtins.isInt (attach.vlan or null) then attach.vlan else null;
      fabricNat44SourcePrefixes = if nat4Enabled then nat44SourcePrefixes else [ ];
      fabricReturnRouteSubnets =
        if nat4Enabled then nat44SourcePrefixes else [ ];
    in
    {
      required = nat4Enabled;
      egressBridge = bridgeName;
      vlanId = vlanValue;
      hostMasqueradePrefixes4 = fabricNat44SourcePrefixes;
      returnRouteSubnets = fabricReturnRouteSubnets;
    };
  allTranslationRecords = translationRecords ++ map
    (record: {
      family = record.family;
      mode = record.translationMode;
      trafficClass = "public-ingress";
      relationId = record.relationId;
      sourceScope = record.sourceScope;
      ingressSurface = {
        publicSurface = record.publicSurface;
        ingressInterface = record.ingressInterface;
        publicAddressBinding = record.publicAddressBinding;
      };
      target = record.target;
      tuples = record.tupleRecords;
      sourceTranslation = record.sourceTranslation;
      returnBehavior = record.returnBehavior;
      consumers = record.consumers;
    }) publicIngress;
in
{
  enabled = natEnabled || publicIngressNatEnabled;
  families = {
    ipv4 = nat4Enabled || builtins.any (record: (record.family or null) == 4) publicIngress;
    ipv6 = nat6Enabled;
  };
  warnings = nat66Warning;
  diagnostics = {
    nat66 = nat66Diagnostics;
  };
  translationRecords = allTranslationRecords;
  inherit publicIngress;
  uplinks = selectedUplinks;
  wanInterfaces = wanRuntimeNames;
  transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
  masqueradeInterfaces = if natEnabled then map (iface: iface.runtimeIfName) wanInterfaces else [ ];
  masqueradeInterfaces4 =
    if nat4Enabled then
      nat44RuntimeNames
    else
      [ ];
  masqueradeInterfaces6 =
    if nat6Enabled then
      nat66RuntimeNames
    else
      [ ];
  masqueradeSourcePrefixes4 = builtins.trace "DBG relcount=${builtins.toJSON (builtins.length (listOrEmpty ((attrsOrEmpty (siteAttrs.communicationContract or null)).relations or null)))} rels=${builtins.toJSON (listOrEmpty ((attrsOrEmpty (siteAttrs.communicationContract or null)).relations or null))}" (if nat4Enabled then nat44SourcePrefixes else [ ]);
  masqueradeSourcePrefixes6 = if nat6Enabled then nat66SourcePrefixes else [ ];
  masqueradeFabricPrefixes4 = if nat4Enabled then masqueradeFabricPrefixes4 else [ ];
  masqueradeFabricPrefixes6 = if nat6Enabled then masqueradeFabricPrefixes6 else [ ];
  tcpMssClampInterfaces = map (iface: iface.runtimeIfName) wanInterfaces;
  uplinkFamilies = {
    ipv4 = map (iface: iface.runtimeIfName) (builtins.filter hasHostIPv4 wanInterfaces);
    ipv6 = map (iface: iface.runtimeIfName) (builtins.filter hasHostIPv6 wanInterfaces);
  };
  routeSafety = {
    coreOriginUplinkDefault = coreUplinkRouteSafety;
  };
  inherit hostNat;
}
