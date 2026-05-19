{ lib, dnsPolicy, context }:

let
  inherit (dnsPolicy) relationEndpointMatchesTenant;
  inherit (context)
    allowedDnsExternalRelations
    deniedDnsExternalRelations
    externalEndpointsOverlap
    hostedDnsServicesForListeners
    relationPriority
    ;

  blockedTenantsFor = tenantNames:
    builtins.filter
      (tenantName:
        builtins.any
          (deny:
            let
              denyPriority = relationPriority deny;
              hasMatchingAllow =
                builtins.any
                  (allow:
                    relationPriority allow <= denyPriority
                    && externalEndpointsOverlap (allow.to or { }) (deny.to or { })
                    && relationEndpointMatchesTenant tenantName (allow.from or null)
                    && relationEndpointMatchesTenant tenantName (deny.from or null))
                  allowedDnsExternalRelations;
            in
            !hasMatchingAllow && relationEndpointMatchesTenant tenantName (deny.from or null))
          deniedDnsExternalRelations)
      tenantNames;
in
{
  inherit blockedTenantsFor;

  blockedForTenants = tenantNames: (builtins.length (blockedTenantsFor tenantNames)) > 0;

  blockedForListeners = listenAddrs:
    let
      hostedDnsServices = hostedDnsServicesForListeners listenAddrs;
    in
    builtins.any
      (relation:
        builtins.isAttrs (relation.from or null)
        && (relation.from.kind or null) == "service"
        && builtins.elem (relation.from.name or "") hostedDnsServices)
      allowedDnsExternalRelations;
}
