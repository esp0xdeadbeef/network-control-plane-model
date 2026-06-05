{ lib
, helpers
, failInventory
,
}:

let
  inherit (helpers)
    isNonEmptyString
    requireAttrs
    requireList
    requireString
    ;

  normalizeStringList = path: value:
    let
      entries = requireList path value;
      normalized =
        builtins.map
          (entry:
            let rendered = requireString "${path}[*]" entry;
            in if isNonEmptyString rendered then rendered else failInventory path "must not contain empty strings")
          entries;
    in
    if normalized == [ ] then failInventory path "must contain at least one entry" else normalized;

  requireEnum = path: allowed: value:
    let rendered = requireString path value;
    in
    if builtins.elem rendered allowed then
      rendered
    else
      failInventory path "must be one of ${builtins.concatStringsSep ", " allowed}";

  normalizeNamespaceAuthority = dnsPath: dns:
    let path = "${dnsPath}.namespaceAuthority";
    in
    builtins.map
      (entry:
        let
          entryPath = "${path}[*]";
          attrs = requireAttrs entryPath entry;
        in
        {
          namespace = requireString "${entryPath}.namespace" (attrs.namespace or null);
          ownerScope = requireString "${entryPath}.ownerScope" (attrs.ownerScope or null);
          requesterScopes = normalizeStringList "${entryPath}.requesterScopes" (attrs.requesterScopes or null);
          addressFamilies = normalizeStringList "${entryPath}.addressFamilies" (attrs.addressFamilies or null);
          fallbackBehavior = requireString "${entryPath}.fallbackBehavior" (attrs.fallbackBehavior or null);
        } // lib.optionalAttrs (attrs ? recordSources) {
          recordSources = normalizeStringList "${entryPath}.recordSources" attrs.recordSources;
        })
      (requireList path (dns.namespaceAuthority or [ ]));

  normalizeLeaseNameScopes = dnsPath: dns:
    let path = "${dnsPath}.leaseNameScopes";
    in
    builtins.map
      (entry:
        let
          entryPath = "${path}[*]";
          attrs = requireAttrs entryPath entry;
        in
        {
          name = requireString "${entryPath}.name" (attrs.name or null);
          namespace = requireString "${entryPath}.namespace" (attrs.namespace or null);
          recordSource = requireEnum "${entryPath}.recordSource" [ "dhcp4-lease" "dhcpv6-lease" ] (attrs.recordSource or null);
          ownerScope = requireString "${entryPath}.ownerScope" (attrs.ownerScope or null);
          requesterScopes = normalizeStringList "${entryPath}.requesterScopes" (attrs.requesterScopes or null);
          addressFamily = requireEnum "${entryPath}.addressFamily" [ "ipv4" "ipv6" ] (attrs.addressFamily or null);
          addresses = normalizeStringList "${entryPath}.addresses" (attrs.addresses or null);
          scopeDenialDiagnostic = requireString "${entryPath}.scopeDenialDiagnostic" (attrs.scopeDenialDiagnostic or null);
        } // lib.optionalAttrs (attrs ? deniedRequesterScopes) {
          deniedRequesterScopes = normalizeStringList "${entryPath}.deniedRequesterScopes" attrs.deniedRequesterScopes;
        })
      (requireList path (dns.leaseNameScopes or [ ]));

  normalizeRecordPublications = dnsPath: dns:
    let path = "${dnsPath}.recordPublications";
    in
    builtins.map
      (entry:
        let
          entryPath = "${path}[*]";
          attrs = requireAttrs entryPath entry;
        in
        {
          name = requireString "${entryPath}.name" (attrs.name or null);
          namespace = requireString "${entryPath}.namespace" (attrs.namespace or null);
          recordSource = requireEnum "${entryPath}.recordSource" [ "static" "reverse" "discovery" ] (attrs.recordSource or null);
          ownerScope = requireString "${entryPath}.ownerScope" (attrs.ownerScope or null);
          requesterScopes = normalizeStringList "${entryPath}.requesterScopes" (attrs.requesterScopes or null);
          addressFamilies = normalizeStringList "${entryPath}.addressFamilies" (attrs.addressFamilies or null);
          publicationScopes = normalizeStringList "${entryPath}.publicationScopes" (attrs.publicationScopes or null);
          publicationDenialDiagnostic = requireString "${entryPath}.publicationDenialDiagnostic" (attrs.publicationDenialDiagnostic or null);
        } // lib.optionalAttrs (attrs ? reverseName) {
          reverseName = requireString "${entryPath}.reverseName" attrs.reverseName;
        })
      (requireList path (dns.recordPublications or [ ]));

  normalizeNamespaceDiagnostics = dnsPath: dns:
    let path = "${dnsPath}.namespaceDiagnostics";
    in
    builtins.map
      (entry:
        let
          entryPath = "${path}[*]";
          attrs = requireAttrs entryPath entry;
          resolutionAuthority = requireString "${entryPath}.resolutionAuthority" (attrs.resolutionAuthority or null);
          _notRendererLocal =
            if resolutionAuthority == "renderer-local-order" then
              failInventory "${entryPath}.resolutionAuthority" "must not use renderer-local resolution order for namespace conflicts"
            else
              true;
        in
        builtins.seq _notRendererLocal {
          namespace = requireString "${entryPath}.namespace" (attrs.namespace or null);
          diagnosticType =
            requireEnum "${entryPath}.diagnosticType"
              [ "conflict" "duplicate-lease" "stale-lease" "ambiguous-reverse" ]
              (attrs.diagnosticType or null);
          recordNames = normalizeStringList "${entryPath}.recordNames" (attrs.recordNames or null);
          behavior = requireString "${entryPath}.behavior" (attrs.behavior or null);
          reason = requireString "${entryPath}.reason" (attrs.reason or null);
          inherit resolutionAuthority;
        })
      (requireList path (dns.namespaceDiagnostics or [ ]));

in
{
  inherit
    normalizeLeaseNameScopes
    normalizeNamespaceAuthority
    normalizeNamespaceDiagnostics
    normalizeRecordPublications
    ;
}
