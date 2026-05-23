{
  lib,
  helpers,
  common,
  overlayNames,
}:

let
  inherit (helpers) isNonEmptyString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty;

  stripPrefixLength =
    value: if !isNonEmptyString value then "" else builtins.head (lib.splitString "/" value);

  hostPrefixFor =
    family: value:
    let
      address = stripPrefixLength value;
    in
    if !isNonEmptyString address then
      null
    else
      {
        inherit family;
        prefix = "${address}/${if family == 4 then "32" else "128"}";
      };

  isDefaultRoute =
    route:
    (route.dst or null) == "0.0.0.0/0"
    || (route.dst or null) == "::/0"
    || (route.dst or null) == "0000:0000:0000:0000:0000:0000:0000:0000/0";

  hasDefault =
    family: routes:
    let
      dst = if family == 4 then "0.0.0.0/0" else "::/0";
    in
    builtins.any (route: (route.dst or null) == dst) (listOrEmpty routes);

  addPreferredSource =
    family: preferredSources: route:
    if !(builtins.isAttrs route) || !(isDefaultRoute route) then
      route
    else
      route
      // lib.optionalAttrs (family == 4 && isNonEmptyString (preferredSources.ipv4 or "")) {
        preferredSource = preferredSources.ipv4;
      }
      // lib.optionalAttrs (family == 6 && isNonEmptyString (preferredSources.ipv6 or "")) {
        preferredSource = preferredSources.ipv6;
      };

  addToRoutes =
    preferredSources: routes:
    if !builtins.isAttrs routes then
      routes
    else
      routes
      // lib.optionalAttrs (builtins.isList (routes.ipv4 or null)) {
        ipv4 = map (addPreferredSource 4 preferredSources) (listOrEmpty routes.ipv4);
      }
      // lib.optionalAttrs (builtins.isList (routes.ipv6 or null)) {
        ipv6 = map (addPreferredSource 6 preferredSources) (listOrEmpty routes.ipv6);
      };
in
{
  contractFor =
    {
      nodeRole,
      uplinkAttrs,
      loopback,
    }:
    let
      overlayUplinks = builtins.filter (uplinkName: builtins.elem uplinkName overlayNames) (
        sortedNames uplinkAttrs
      );
      ipv4Source = stripPrefixLength (loopback.ipv4 or "");
      ipv6Source = stripPrefixLength (loopback.ipv6 or "");
      sourcePrefixes = builtins.filter (prefix: prefix != null) [
        (hostPrefixFor 4 (loopback.ipv4 or ""))
        (hostPrefixFor 6 (loopback.ipv6 or ""))
      ];
    in
    if nodeRole == "core" && overlayUplinks != [ ] && sourcePrefixes != [ ] then
      {
        enabled = true;
        uplinks = overlayUplinks;
        preferredSources =
          lib.optionalAttrs (isNonEmptyString ipv4Source) { ipv4 = ipv4Source; }
          // lib.optionalAttrs (isNonEmptyString ipv6Source) { ipv6 = ipv6Source; };
        inherit sourcePrefixes;
      }
    else
      null;

  applyToInterfaces =
    runtimeOriginEgress: interfaces:
    if !(builtins.isAttrs runtimeOriginEgress) then
      interfaces
    else
      let
        preferredSources = runtimeOriginEgress.preferredSources or { };
        isRuntimeOriginP2p =
          iface:
          (iface.sourceKind or null) == "p2p"
          && (
            hasDefault 4 ((attrsOrEmpty (iface.routes or null)).ipv4 or [ ])
            || hasDefault 6 ((attrsOrEmpty (iface.routes or null)).ipv6 or [ ])
          );
      in
      lib.mapAttrs (
        _ifName: iface:
        if isRuntimeOriginP2p iface then
          iface // { routes = addToRoutes preferredSources (iface.routes or { }); }
        else
          iface
      ) interfaces;
}
