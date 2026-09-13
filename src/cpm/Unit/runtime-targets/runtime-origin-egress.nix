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

  hasModeledRuntimeOriginUnderlay =
    interfaces:
    builtins.any
      (
        iface:
        (iface.sourceKind or null) == "p2p"
        && (
          hasDefault 4 ((attrsOrEmpty (iface.routes or null)).ipv4 or [ ])
          || hasDefault 6 ((attrsOrEmpty (iface.routes or null)).ipv6 or [ ])
        )
      )
      (builtins.attrValues (attrsOrEmpty interfaces));

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
      interfaces ? null,
      egressIntent ? null,
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
      sourceHasModeledUnderlay =
        if interfaces == null then true else hasModeledRuntimeOriginUnderlay interfaces;
      # FS-370-HDS-010-SDS-010-SMS-010: the egress identity is owned by the
      # forwarding model. The overlay-egress preferred source belongs to the node
      # the forwarding model marks as a modeled exit with an eligible egress
      # surface, not to every core by role. A node with no modeled egress is not
      # an overlay-egress runtime-origin owner.
      modeledEgress =
        egressIntent != null
        && (egressIntent.exit or false) == true
        && (egressIntent.eligible or false) == true;
    in
    if modeledEgress && sourcePrefixes != [ ] && sourceHasModeledUnderlay then
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
        carriesDefault =
          iface:
          hasDefault 4 ((attrsOrEmpty (iface.routes or null)).ipv4 or [ ])
          || hasDefault 6 ((attrsOrEmpty (iface.routes or null)).ipv6 or [ ]);
        # FS-370-HDS-010-SDS-010-SMS-010 / FS-540-HDS-010-SDS-010-SMS-010: the
        # preferred source is realized as exactly ONE preferred-source default
        # per address family on the modeled deterministic route to the selected
        # egress surface. Decorate exactly one default-carrying interface (the
        # egress route), preferring the modeled core-egress surface; never
        # duplicate the mechanic across several default-carrying interfaces.
        isEgressSurface =
          name: iface: (iface.sourceKind or null) == "core-egress";
        defaultInterfaces =
          builtins.filter
            (entry: carriesDefault entry.v)
            (map (n: { inherit n; v = interfaces.${n}; }) (builtins.attrNames interfaces));
        chosenName =
          if defaultInterfaces == [ ] then
            null
          else
            let
              egressSurface =
                builtins.filter (e: isEgressSurface e.n e.v) defaultInterfaces;
            in
            (if egressSurface != [ ] then builtins.head egressSurface else builtins.head defaultInterfaces).n;
      in
      lib.mapAttrs (
        ifName: iface:
        if ifName == chosenName then
          iface // { routes = addToRoutes preferredSources (iface.routes or { }); }
        else
          iface
      ) interfaces;
}
