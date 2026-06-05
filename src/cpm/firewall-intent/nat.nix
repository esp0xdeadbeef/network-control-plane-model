{ helpers }:

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
, interfaceRecords
, target
, runtimeOriginSourcePrefixes ? [ ]
,
}:
let
  siteTenantPrefixes = listOrEmpty ((attrsOrEmpty (siteAttrs.domains or null)).tenants or null);
  siteOwnershipPrefixes = listOrEmpty ((attrsOrEmpty (siteAttrs.ownership or null)).prefixes or null);
  siteNat44SourcePrefixes =
    builtins.map prefixValue (
      builtins.filter isPrivate4Prefix (
        (builtins.map (tenant: if builtins.isAttrs tenant then tenant.ipv4 or "" else tenant) siteTenantPrefixes)
        ++ (builtins.map (prefix: if builtins.isAttrs prefix then prefix.ipv4 or prefix.prefix or "" else prefix) siteOwnershipPrefixes)
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
  nat44SourcePrefixes = uniqueStrings (
    builtins.concatMap (intent: listOrEmpty (intent.sourcePrefixes or null)) nat44SelectedIntents
    ++ siteNat44SourcePrefixes
    ++ runtimeOriginNat44SourcePrefixes
  );
  nat66ByUplink = attrsOrEmpty (egressIntent.nat66 or null);
  nat66SelectedIntents = map (uplink: attrsOrEmpty (nat66ByUplink.${uplink} or null)) selectedUplinks;
  nat66Requested = builtins.any (intent: (intent.mode or null) == "nat66") nat66SelectedIntents;
  trafficClass = egressIntent.trafficClass or "internet-egress";
  nat66SourcePrefixes = uniqueStrings (
    builtins.concatMap (intent: listOrEmpty (intent.sourcePrefixes or null)) nat66SelectedIntents
    ++ runtimeOriginNat66SourcePrefixes
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
  tenantNames = uniqueStrings (
    map (tenant: if builtins.isAttrs tenant then tenant.name or "" else "") (
      listOrEmpty ((attrsOrEmpty (siteAttrs.domains or null)).tenants or null)
    )
  );
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
in
{
  enabled = natEnabled;
  families = {
    ipv4 = nat4Enabled;
    ipv6 = nat6Enabled;
  };
  warnings = nat66Warning;
  diagnostics = {
    nat66 = nat66Diagnostics;
  };
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
  masqueradeSourcePrefixes4 = if nat4Enabled then nat44SourcePrefixes else [ ];
  masqueradeSourcePrefixes6 = if nat6Enabled then nat66SourcePrefixes else [ ];
  tcpMssClampInterfaces = map (iface: iface.runtimeIfName) wanInterfaces;
  uplinkFamilies = {
    ipv4 = map (iface: iface.runtimeIfName) (builtins.filter hasHostIPv4 wanInterfaces);
    ipv6 = map (iface: iface.runtimeIfName) (builtins.filter hasHostIPv6 wanInterfaces);
  };
  routeSafety = {
    coreOriginUplinkDefault = coreUplinkRouteSafety;
  };
}
