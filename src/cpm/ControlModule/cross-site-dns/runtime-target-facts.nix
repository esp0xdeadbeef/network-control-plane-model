{ lib
, helpers
, common
, runtimeTargetEntries
, entryKey
,
}:

let
  inherit (helpers) isNonEmptyString;
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  targetTenantNames =
    target:
    uniqueStrings (
      builtins.map
        (attachment: attachment.name)
        (builtins.filter
          (attachment:
          builtins.isAttrs attachment
          && (attachment.kind or null) == "tenant"
          && isNonEmptyString (attachment.name or null))
          (listOrEmpty (target.attachments or null)))
    );

  dnsListenersForTarget =
    target:
    let dns = attrsOrEmpty ((attrsOrEmpty (target.services or null)).dns or null);
    in uniqueStrings (listOrEmpty (dns.listen or null));

  dnsForwardersForTarget =
    target:
    let dns = attrsOrEmpty ((attrsOrEmpty (target.services or null)).dns or null);
    in uniqueStrings (listOrEmpty (dns.forwarders or null));

  interfaceCidrsForTarget =
    target:
    let
      interfaces = attrsOrEmpty ((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null);
    in
    uniqueStrings (
      builtins.concatLists (
        builtins.map
          (ifName:
          let iface = attrsOrEmpty interfaces.${ifName};
          in
          (lib.optional (isNonEmptyString (iface.addr4 or null)) iface.addr4)
          ++ (lib.optional (isNonEmptyString (iface.addr6 or null)) iface.addr6))
          (builtins.attrNames interfaces)
      )
    );

  runtimeOriginSourceCidrsForTarget =
    target:
    uniqueStrings (
      builtins.map
        (source: source.prefix)
        (
          builtins.filter
            (source: isNonEmptyString (source.prefix or null))
            (listOrEmpty ((attrsOrEmpty (target.runtimeOriginEgress or null)).sourcePrefixes or null))
        )
    );

  dnsEgressSourceCidrsForTarget =
    target:
    let
      dns = attrsOrEmpty ((attrsOrEmpty (target.services or null)).dns or null);
      roles = attrsOrEmpty (dns.roles or null);
      recursion = attrsOrEmpty (roles.recursion or null);
      sources =
        if listOrEmpty (recursion.outgoingInterfaces or null) != [ ] then
          listOrEmpty (recursion.outgoingInterfaces or null)
        else
          listOrEmpty (dns.outgoingInterfaces or null);
      sourceToCidr = source:
        if !isNonEmptyString source then
          null
        else if builtins.match ".*:.*" source != null then
          "${source}/128"
        else
          "${source}/32";
    in
    uniqueStrings (builtins.filter isNonEmptyString (builtins.map sourceToCidr sources));
in
{
  inherit interfaceCidrsForTarget;

  facts =
    builtins.map
      (entry:
      entry
      // {
        key = entryKey entry;
        tenantNames = targetTenantNames entry.target;
        dnsListeners = dnsListenersForTarget entry.target;
        dnsForwarders = dnsForwardersForTarget entry.target;
        interfaceCidrs = interfaceCidrsForTarget entry.target;
        runtimeOriginSourceCidrs = runtimeOriginSourceCidrsForTarget entry.target;
        dnsEgressSourceCidrs = dnsEgressSourceCidrsForTarget entry.target;
      })
      runtimeTargetEntries;
}
