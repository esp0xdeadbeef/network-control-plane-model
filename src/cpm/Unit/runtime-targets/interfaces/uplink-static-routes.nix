{ helpers, common }:

let
  inherit (common) listOrEmpty;
  binderSourceAudit = import ../../../binder-source-audit.nix { inherit helpers; };

  routeFor =
    family: route:
    let
      viaField = if family == 4 then "via4" else "via6";
      dst = route.prefix or route.dst or null;
      upstreamBehaviorRef = route.upstreamBehaviorRef or route.traceBackRef or null;
      routePath = route.binderSourcePath or "inventory.controlPlane.uplinks.<unknown>.egress.static.routes";
      routeRecord = {
        dst = dst;
        proto = "upstream";
        intent = {
          kind =
            if (family == 4 && dst == "0.0.0.0/0")
               || (family == 6 && dst == "::/0")
            then
              "default-reachability"
            else
              "uplink-learned-reachability";
          source = "explicit-uplink-static";
        };
        ${viaField} = route.via or route.${viaField} or null;
      };
    in
    if upstreamBehaviorRef == null then
      routeRecord
    else
      binderSourceAudit.makeRoute {
        path = routePath;
        field = "runtimeTargets.*.effectiveRuntimeRealization.interfaces.*.routes.${if family == 4 then "ipv4" else "ipv6"}[]";
        binderSourceClass = "public-inventory";
        binderSourcePath = routePath;
        upstreamBehaviorRef = upstreamBehaviorRef;
        route = routeRecord;
      };
in
uplinkCfg:
let
  staticRoutes = ((uplinkCfg.static or { }).routes or { });
in
{
  ipv4 = builtins.map (routeFor 4) (listOrEmpty (staticRoutes.ipv4 or null));
  ipv6 = builtins.map (routeFor 6) (listOrEmpty (staticRoutes.ipv6 or null));
}
