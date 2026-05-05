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

  overlayLaneDefaultAllowed =
    route:
    let
      lane = attrsOrEmpty (route.lane or null);
      uplinkName = lane.uplink or null;
      accessNodeName = lane.access or null;
    in
    !(
      isNonEmptyString uplinkName
      && hasAttr uplinkName siteOverlayNameSet
      && !(isNonEmptyString accessNodeName && isDelegatedIPv6AccessNode accessNodeName)
    );

  stripNonDelegatedOverlayDefaults =
    family: routes:
    builtins.filter
      (route:
        let isDefault = (route.dst or null) == (if family == 4 then "0.0.0.0/0" else "::/0");
        in !isDefault || overlayLaneDefaultAllowed route)
      routes;

  sanitizeDefaultRoutes =
    family: routes:
    stripDefaultRoutes family (stripNonDelegatedOverlayDefaults family routes);
in
{
  inherit sanitizeDefaultRoutes stripNonDelegatedOverlayDefaults;

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
                    { ipv4 = stripNonDelegatedOverlayDefaults 4 (routes.ipv4 or [ ]); }
                  else
                    { ipv6 = stripNonDelegatedOverlayDefaults 6 (routes.ipv6 or [ ]); }
                );
            })
          targetView.interfaces;
    in
    target // { effectiveRuntimeRealization = targetView.effective // { inherit interfaces; }; };
}
