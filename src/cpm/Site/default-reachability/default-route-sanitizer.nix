{
  common,
  helpers,
  isDelegatedIPv6AccessNode,
  siteOverlayNameSet,
  targetInterfaces,
}:

let
  inherit (helpers) hasAttr isNonEmptyString;
  inherit (common) attrsOrEmpty stripDefaultRoutes;

  laneHelpers = import ../topology/lane-metadata.nix { inherit helpers; };
  inherit (laneHelpers) effectiveRouteLane;

  defaultAllowed =
    family: iface: route:
    let
      lane = effectiveRouteLane iface route;
      uplinkName = lane.uplink or null;
      accessNodeName = lane.access or null;
      usesOverlay = isNonEmptyString uplinkName && hasAttr uplinkName siteOverlayNameSet;
      delegatedAccess = isNonEmptyString accessNodeName && isDelegatedIPv6AccessNode accessNodeName;
    in
    (
      !usesOverlay || delegatedAccess
    )
    && !(family == 6 && delegatedAccess && isNonEmptyString uplinkName && !usesOverlay);

  stripNonDelegatedOverlayDefaults =
    family: iface: routes:
    builtins.filter
      (route:
        let isDefault = (route.dst or null) == (if family == 4 then "0.0.0.0/0" else "::/0");
        in !isDefault || defaultAllowed family iface route)
      routes;

  sanitizeDefaultRoutes =
    family: routes:
    stripDefaultRoutes family (stripNonDelegatedOverlayDefaults family { } routes);

  sanitizeDefaultRoutesForInterface =
    family: iface: routes:
    stripDefaultRoutes family (stripNonDelegatedOverlayDefaults family iface routes);

  stripNonDelegatedOverlayDefaultsForInterface =
    family: iface: routes:
    stripNonDelegatedOverlayDefaults family iface routes;
in
{
  inherit
    sanitizeDefaultRoutes
    sanitizeDefaultRoutesForInterface
    stripNonDelegatedOverlayDefaults
    stripNonDelegatedOverlayDefaultsForInterface
    ;

  sanitizeOverlayDefaults = family: targetPath: target:
    let
      targetView = targetInterfaces targetPath target;
      interfaces =
        builtins.mapAttrs
          (_: iface:
            let routes = attrsOrEmpty (iface.routes or null);
            in
            iface
            // {
              routes =
                routes
                // (
                  if family == 4 then
                    { ipv4 = stripNonDelegatedOverlayDefaultsForInterface 4 iface (routes.ipv4 or [ ]); }
                  else
                    { ipv6 = stripNonDelegatedOverlayDefaultsForInterface 6 iface (routes.ipv6 or [ ]); }
                );
            })
          targetView.interfaces;
    in
    target // { effectiveRuntimeRealization = targetView.effective // { inherit interfaces; }; };
}
