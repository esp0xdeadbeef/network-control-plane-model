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
      delegatedPrefixLength = prefix.delegatedPrefixLength or null;
      perTenantPrefixLength = prefix.perTenantPrefixLength or null;
      slot = prefix.slot or null;
      validDerivation =
        builtins.isInt delegatedPrefixLength
        && builtins.isInt perTenantPrefixLength
        && builtins.isInt slot
        && delegatedPrefixLength >= 0
        && delegatedPrefixLength <= 128
        && perTenantPrefixLength >= delegatedPrefixLength
        && perTenantPrefixLength <= 128
        && slot >= 0;
    in
    if family == null || !isNonEmptyString sourceFile then
      null
    else if !validDerivation then
      throw "FS-350-HDS-010-SDS-010-SMS-060: runtime routed prefix for tenant '${tenantName}' lacks valid delegatedPrefixLength, perTenantPrefixLength, or slot derivation metadata"
    else
      {
        inherit
          family
          sourceFile
          delegatedPrefixLength
          perTenantPrefixLength
          slot
          ;
        tenant = tenantName;
        proto = "internal";
        intent = {
          kind = "runtime-routed-prefix-return";
          source = "intent-routed-prefix";
          accessNode = nodeName;
        };
      }
      // (
        let
          prefixName = prefix.prefixName or prefix.name or null;
        in
        if isNonEmptyString prefixName then { inherit prefixName; } else { }
      )
      // (
        if isNonEmptyString (prefix.prefixPostfix or null) then { inherit (prefix) prefixPostfix; } else { }
      );
in
{
  nodeName,
  tenantName,
  routedPrefixesByTenant,
}:
if tenantName == null then
  {
    ipv4 = [ ];
    ipv6 = [ ];
  }
else
  let
    routes = builtins.filter (route: route != null) (
      builtins.map (routeForPrefix { inherit nodeName tenantName; }) (
        listOrEmpty (routedPrefixesByTenant.${tenantName} or null)
      )
    );
  in
  {
    ipv4 = builtins.filter (route: (route.family or null) == 4) routes;
    ipv6 = builtins.filter (route: (route.family or null) == 6) routes;
  }
