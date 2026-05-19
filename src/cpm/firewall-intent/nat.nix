{ helpers }:

let
  inherit (helpers) isNonEmptyString sortedNames;
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];
  uniqueStrings = values:
    sortedNames (builtins.listToAttrs (map (value: { name = value; value = true; }) (builtins.filter isNonEmptyString values)));

  hasHostIPv4 = iface:
    builtins.isAttrs ((attrsOrEmpty (iface.hostUplink or null)).ipv4 or null);
  hasHostIPv6 = iface:
    builtins.isAttrs ((attrsOrEmpty (iface.hostUplink or null)).ipv6 or null);

in
{ siteAttrs, overlayNames, interfaceRecords, target }:
let
  egressIntent = attrsOrEmpty (target.egressIntent or null);
  exitEnabled = (egressIntent.exit or false) == true;
  selectedUplinks = uniqueStrings (listOrEmpty (egressIntent.uplinks or null) ++ listOrEmpty (egressIntent.wanInterfaces or null));
  transitInterfaces = builtins.filter (iface: iface.sourceKind == "p2p") interfaceRecords;
  wanInterfaces =
    builtins.filter
      (iface:
        iface.sourceKind == "wan"
        && !(builtins.elem (iface.upstream or "") overlayNames)
        && (selectedUplinks == [ ] || builtins.elem (iface.upstream or "") selectedUplinks || builtins.elem iface.sourceInterfaceName selectedUplinks))
      interfaceRecords;
  nat4Enabled = exitEnabled && builtins.any hasHostIPv4 wanInterfaces;
  nat6Enabled = false;
  natEnabled = nat4Enabled || nat6Enabled;
in
{
  enabled = natEnabled;
  families = { ipv4 = nat4Enabled; ipv6 = nat6Enabled; };
  uplinks = selectedUplinks;
  wanInterfaces = map (iface: iface.runtimeIfName) wanInterfaces;
  transitInterfaces = map (iface: iface.runtimeIfName) transitInterfaces;
  masqueradeInterfaces = if natEnabled then map (iface: iface.runtimeIfName) wanInterfaces else [ ];
  masqueradeInterfaces4 = if nat4Enabled then map (iface: iface.runtimeIfName) (builtins.filter hasHostIPv4 wanInterfaces) else [ ];
  masqueradeInterfaces6 = if nat6Enabled then map (iface: iface.runtimeIfName) (builtins.filter hasHostIPv6 wanInterfaces) else [ ];
  masqueradeSourcePrefixes6 = [ ];
  tcpMssClampInterfaces = map (iface: iface.runtimeIfName) wanInterfaces;
  uplinkFamilies = {
    ipv4 = map (iface: iface.runtimeIfName) (builtins.filter hasHostIPv4 wanInterfaces);
    ipv6 = map (iface: iface.runtimeIfName) (builtins.filter hasHostIPv6 wanInterfaces);
  };
}
