{ helpers }:

let
  inherit (helpers) isNonEmptyString sortedNames;
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];
  uniqueStrings =
    values:
    sortedNames (
      builtins.listToAttrs (
        map
          (value: {
            name = value;
            value = true;
          })
          (builtins.filter isNonEmptyString values)
      )
    );

  hasHostIPv4 = iface: builtins.isAttrs ((attrsOrEmpty (iface.hostUplink or null)).ipv4 or null);
  hasHostIPv6 = iface: builtins.isAttrs ((attrsOrEmpty (iface.hostUplink or null)).ipv6 or null);

in
{ siteAttrs
, overlayNames
, interfaceRecords
, target
, runtimeOriginSourcePrefixes ? [ ]
,
}:
let
  prefixValue = prefix:
    if builtins.isAttrs prefix then prefix.prefix or "" else if builtins.isString prefix then prefix else "";
  prefixFamily = prefix:
    if builtins.isAttrs prefix then prefix.family or null else if builtins.match ".*:.*" prefix != null then 6 else 4;
  isUla6Prefix = prefix:
    let
      value = prefixValue prefix;
    in
    prefixFamily prefix == 6 && builtins.match "[fF][cCdD].*" value != null;
  runtimeOriginNat66SourcePrefixes =
    builtins.map prefixValue (builtins.filter isUla6Prefix (listOrEmpty runtimeOriginSourcePrefixes));
  egressIntent = attrsOrEmpty (target.egressIntent or null);
  exitEnabled = (egressIntent.exit or false) == true;
  coreOriginUplinkDefaultAllowed = (egressIntent.coreOriginUplinkDefaultAllowed or false) == true;
  selectedUplinks = uniqueStrings (
    listOrEmpty (egressIntent.uplinks or null) ++ listOrEmpty (egressIntent.wanInterfaces or null)
  );
  nat66ByUplink = attrsOrEmpty (egressIntent.nat66 or null);
  nat66SelectedIntents = map (uplink: attrsOrEmpty (nat66ByUplink.${uplink} or null)) selectedUplinks;
  nat66SourcePrefixes = uniqueStrings (
    builtins.concatMap (intent: listOrEmpty (intent.sourcePrefixes or null)) nat66SelectedIntents
    ++ runtimeOriginNat66SourcePrefixes
  );
  explicitNat66Interfaces = builtins.filter
    (
      iface:
      let
        wan = attrsOrEmpty (iface.wan or null);
        egress = attrsOrEmpty (wan.egress or null);
        ipv6 = attrsOrEmpty (egress.ipv6 or null);
        translation = attrsOrEmpty (ipv6.translation or null);
        modeledNat66 = attrsOrEmpty (nat66ByUplink.${iface.upstream or ""} or null);
      in
      (translation.mode or null) == "nat66" && (modeledNat66.mode or null) == "nat66"
    )
    interfaceRecords;
  explicitNat66RuntimeNames = map (iface: iface.runtimeIfName) explicitNat66Interfaces;
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
  wanInterfaces = builtins.filter
    (
      iface:
      iface.sourceKind == "wan"
      && !(builtins.elem (iface.upstream or "") overlayNames)
      && (
        selectedUplinks == [ ]
        || builtins.elem (iface.upstream or "") selectedUplinks
        || builtins.elem iface.sourceInterfaceName selectedUplinks
      )
    )
    interfaceRecords;
  nat4Enabled = exitEnabled && builtins.any hasHostIPv4 wanInterfaces;
  nat6Enabled =
    exitEnabled
    && explicitNat66Interfaces != [ ]
    && nat66SourcePrefixes != [ ]
    && builtins.any hasHostIPv6 wanInterfaces;
  natEnabled = nat4Enabled || nat6Enabled;
  coreUplinkRouteSafety =
    let
      applies = (target.role or null) == "core" && exitEnabled && selectedUplinks != [ ];
    in
    if !applies then
      { applies = false; }
    else
      {
        applies = true;
        mode = if coreOriginUplinkDefaultAllowed then "explicitly-allowed" else "blackholed";
        blackholed = !coreOriginUplinkDefaultAllowed;
        broadCoreOriginUplinkRoutingAllowed = coreOriginUplinkDefaultAllowed;
        selectedUplinks = selectedUplinks;
        sourceScopedTranslationExceptions = {
          nat44 = nat4Enabled;
          nat66 = nat6Enabled;
          snat = natEnabled;
          nat66SourcePrefixes = nat66SourcePrefixes;
          outputInterfaces = map (iface: iface.runtimeIfName) wanInterfaces;
        };
      };
in
{
  enabled = natEnabled;
  families = {
    ipv4 = nat4Enabled;
    ipv6 = nat6Enabled;
  };
  warnings = nat66Warning;
  uplinks = selectedUplinks;
  wanInterfaces = map (iface: iface.runtimeIfName) wanInterfaces;
  transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
  masqueradeInterfaces = if natEnabled then map (iface: iface.runtimeIfName) wanInterfaces else [ ];
  masqueradeInterfaces4 =
    if nat4Enabled then
      map (iface: iface.runtimeIfName) (builtins.filter hasHostIPv4 wanInterfaces)
    else
      [ ];
  masqueradeInterfaces6 =
    if nat6Enabled then
      map (iface: iface.runtimeIfName)
        (
          builtins.filter
            (
              iface: hasHostIPv6 iface && builtins.elem iface.runtimeIfName explicitNat66RuntimeNames
            )
            wanInterfaces
        )
    else
      [ ];
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
