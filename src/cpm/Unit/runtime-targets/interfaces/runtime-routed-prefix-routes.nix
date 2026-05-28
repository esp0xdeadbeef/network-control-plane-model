{ helpers, common }:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) listOrEmpty;

  familyFor =
    value:
    if value == 4 || value == "ipv4" then
      4
    else if value == 6 || value == "ipv6" then
      6
    else
      null;

  routeForPrefix =
    { nodeName, tenantName }:
    prefix:
    let
      family = familyFor (prefix.family or null);
      sourceFile = prefix.sourceFile or null;
    in
    if family == null || !isNonEmptyString sourceFile then
      null
    else
      {
        inherit family sourceFile;
        tenant = tenantName;
        proto = "internal";
        intent = {
          kind = "runtime-routed-prefix-return";
          source = "intent-routed-prefix";
          accessNode = nodeName;
        };
      }
      // (if isNonEmptyString (prefix.prefixName or null) then { prefixName = prefix.prefixName; } else { });
in
{ nodeName, tenantName, routedPrefixesByTenant }:
if tenantName == null then
  { ipv4 = [ ]; ipv6 = [ ]; }
else
  let
    routes = builtins.filter (route: route != null) (
      builtins.map
        (routeForPrefix { inherit nodeName tenantName; })
        (listOrEmpty (routedPrefixesByTenant.${tenantName} or null))
    );
  in
  {
    ipv4 = builtins.filter (route: (route.family or null) == 4) routes;
    ipv6 = builtins.filter (route: (route.family or null) == 6) routes;
  }
