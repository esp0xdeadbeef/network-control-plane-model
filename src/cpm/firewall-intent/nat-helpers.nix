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

  prefixValue = prefix:
    if builtins.isAttrs prefix then prefix.prefix or "" else if builtins.isString prefix then prefix else "";
  prefixFamily = prefix:
    if builtins.isAttrs prefix then prefix.family or null else if builtins.match ".*:.*" prefix != null then 6 else 4;
in
rec {
  inherit attrsOrEmpty listOrEmpty prefixValue uniqueStrings;

  hasHostIPv4 = iface: builtins.isAttrs ((attrsOrEmpty (iface.hostUplink or null)).ipv4 or null);
  hasHostIPv6 = iface: builtins.isAttrs ((attrsOrEmpty (iface.hostUplink or null)).ipv6 or null);
  isIpv4Prefix = prefix: prefixFamily prefix == 4 && prefixValue prefix != "";
  isUla6Prefix = prefix: prefixFamily prefix == 6 && builtins.match "[fF][cCdD].*" (prefixValue prefix) != null;
  isPrivate4Prefix =
    prefix:
    let
      value = prefixValue prefix;
    in
    prefixFamily prefix == 4
    && (
      builtins.match "10\\..*" value != null
      || builtins.match "192\\.168\\..*" value != null
      || builtins.match "172\\.(1[6-9]|2[0-9]|3[0-1])\\..*" value != null
      || builtins.match "100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\..*" value != null
    );

  interfaceIdentities = iface:
    let
      ref = attrsOrEmpty (iface.backingRef or null);
      lane = attrsOrEmpty (ref.lane or null);
    in
    uniqueStrings (
      [
        (iface.upstream or "")
        (iface.sourceInterfaceName or "")
        (iface.runtimeIfName or "")
        (iface.name or "")
        (ref.name or "")
        (lane.uplink or "")
      ]
      ++ listOrEmpty (ref.uplinks or null)
      ++ listOrEmpty (lane.uplinks or null)
    );

  interfaceMatchesIdentity = identity: iface: builtins.elem identity (interfaceIdentities iface);
  interfaceDeclined = declinedInterfaceIdentities: iface:
    builtins.any (identity: interfaceMatchesIdentity identity iface) declinedInterfaceIdentities;

  routeSafety =
    { target
    , exitEnabled
    , selectedUplinks
    , coreOriginUplinkDefaultAllowed
    , declinedInterfaceIdentities
    , nat4Enabled
    , nat6Enabled
    , natEnabled
    , nat44SourcePrefixes
    , nat66SourcePrefixes
    , wanRuntimeNames
    , nat44RuntimeNames
    , nat66RuntimeNames
    }:
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
        selectedUplinkInterfaces = wanRuntimeNames;
        declinedInterfaces = declinedInterfaceIdentities;
        sourceScopedTranslationExceptions = {
          nat44 = nat4Enabled;
          nat66 = nat6Enabled;
          snat = natEnabled;
          nat44SourcePrefixes = if nat4Enabled then nat44SourcePrefixes else [ ];
          nat66SourcePrefixes = if nat6Enabled then nat66SourcePrefixes else [ ];
          snatSourcePrefixes = uniqueStrings (
            (if nat4Enabled then nat44SourcePrefixes else [ ])
            ++ (if nat6Enabled then nat66SourcePrefixes else [ ])
          );
          nat44Boundaries = if nat4Enabled then selectedUplinks else [ ];
          nat66Boundaries = if nat6Enabled then selectedUplinks else [ ];
          snatBoundaries = if natEnabled then selectedUplinks else [ ];
          nat44OutputInterfaces = if nat4Enabled then nat44RuntimeNames else [ ];
          nat66OutputInterfaces = if nat6Enabled then nat66RuntimeNames else [ ];
          outputInterfaces = wanRuntimeNames;
        };
      };
}
