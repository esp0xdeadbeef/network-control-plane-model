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
in
{
  blockedForTenants = tenantNames:
    builtins.any
      (deny:
        let
          denyPriority = relationPriority deny;
          hasMatchingAllow =
            builtins.any
              (allow:
                relationPriority allow <= denyPriority
                && externalEndpointsOverlap (allow.to or { }) (deny.to or { })
                && builtins.any
                  (tenantName:
                    relationEndpointMatchesTenant tenantName (allow.from or null)
                    && relationEndpointMatchesTenant tenantName (deny.from or null))
                  tenantNames)
              allowedDnsExternalRelations;
        in
        !hasMatchingAllow
        && builtins.any (tenantName: relationEndpointMatchesTenant tenantName (deny.from or null)) tenantNames)
      deniedDnsExternalRelations;

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
