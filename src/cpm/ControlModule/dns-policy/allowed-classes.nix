{ lib
, allowedRelations
, dnsPolicy
, context
,
}:

let
  inherit (dnsPolicy)
    relationEndpointMatchesTenant
    ;

  dnsExternalRelation =
    relation:
    let
      relationAttrs = if builtins.isAttrs relation then relation else { };
    in
    (relationAttrs.action or "allow") == "allow"
    && (relationAttrs.trafficType or null) == "dns"
    && builtins.isAttrs (relationAttrs.to or null)
    && (relationAttrs.to.kind or null) == "external";

  dnsExternalRelations = builtins.filter dnsExternalRelation allowedRelations;

in
{
  forTenants =
    tenantNames:
    let
      hasTenantExternalDns =
        builtins.any
          (relation:
            builtins.any
              (tenantName: relationEndpointMatchesTenant tenantName (relation.from or null))
              tenantNames)
          dnsExternalRelations;
    in
    if hasTenantExternalDns then [ "explicit-egress-default" ] else [ ];

  forListeners =
    listenAddrs:
    let
      hostedDnsServices = context.hostedDnsServicesForListeners listenAddrs;
      hasHostedExternalDns =
        builtins.any
          (relation:
            builtins.isAttrs (relation.from or null)
            && (relation.from.kind or null) == "service"
            && builtins.elem (relation.from.name or "") hostedDnsServices)
          dnsExternalRelations;
    in
    if hasHostedExternalDns then [ "explicit-egress-default" ] else [ ];
}
