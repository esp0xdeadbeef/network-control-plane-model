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

  ifaceUplinks =
    iface:
    let
      ref = attrsOrEmpty (iface.backingRef or null);
      lane = attrsOrEmpty (ref.lane or null);
    in
    builtins.filter (uplink: uplink != null) (
      (ref.uplinks or [ ])
      ++ (lane.uplinks or [ ])
      ++ (if (lane.uplink or null) == null then [ ] else [ lane.uplink ])
    );

  firstVia =
    family: routes:
    let
      viaField = if family == 4 then "via4" else "via6";
      matches = builtins.filter (route: isNonEmptyString (route.${viaField} or "")) (listOrEmpty routes);
    in
    if matches == [ ] then "" else (builtins.head matches).${viaField};

  hasDefault =
    family: routes:
    let
      dst = if family == 4 then "0.0.0.0/0" else "::/0";
    in
    builtins.any (route: (route.dst or null) == dst) (listOrEmpty routes);

  runtimeDefaultRoute =
    preferredSources: family: via:
    let
      viaField = if family == 4 then "via4" else "via6";
    in
    {
      inherit family;
      dst = if family == 4 then "0.0.0.0/0" else "::/0";
      proto = "default";
      preferredSource = preferredSources.${if family == 4 then "ipv4" else "ipv6"};
      intent = {
        kind = "runtime-origin-egress";
        source = "loopback-runtime-identity";
      };
      ${viaField} = via;
    };

  addRuntimeDefault =
    preferredSources: family: routes:
    let
      preferredSource = preferredSources.${if family == 4 then "ipv4" else "ipv6"} or "";
      via = firstVia family routes;
    in
    if !isNonEmptyString preferredSource || !isNonEmptyString via || hasDefault family routes then
      listOrEmpty routes
    else
      (listOrEmpty routes) ++ [ (runtimeDefaultRoute preferredSources family via) ];

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
        ipv4 = map (addPreferredSource 4 preferredSources) (addRuntimeDefault preferredSources 4 routes.ipv4);
      }
      // lib.optionalAttrs (builtins.isList (routes.ipv6 or null)) {
        ipv6 = map (addPreferredSource 6 preferredSources) (addRuntimeDefault preferredSources 6 routes.ipv6);
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
        runtimeUplinks = runtimeOriginEgress.uplinks or [ ];
        isRuntimeOriginP2p =
          iface:
          (iface.sourceKind or null) == "p2p"
          && builtins.any (uplink: builtins.elem uplink runtimeUplinks) (ifaceUplinks iface);
      in
      lib.mapAttrs (
        _ifName: iface:
        if isRuntimeOriginP2p iface then
          iface // { routes = addToRoutes preferredSources (iface.routes or { }); }
        else
          iface
      ) interfaces;
}
