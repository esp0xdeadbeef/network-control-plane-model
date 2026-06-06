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

  requireBool = path: value:
    if builtins.isBool value then value else failInventory path "must be a boolean";

  normalizePredicate = path: value: default:
    if value == null then
      default
    else if builtins.isBool value then
      default // {
        present = requireBool path value;
        source = "inventory-realization";
      }
    else
      let attrs = requireAttrs path value;
      in
      default // {
        present = requireBool "${path}.present" (attrs.present or default.present);
        behavior = requireString "${path}.behavior" (attrs.behavior or default.behavior);
        reason = requireString "${path}.reason" (attrs.reason or default.reason);
        source = requireString "${path}.source" (attrs.source or "inventory-realization");
      };

  predicateFromDiagnostics = diagnosticTypes: diagnostics:
    let
      matching = builtins.filter (entry: builtins.elem (entry.diagnosticType or null) diagnosticTypes) diagnostics;
      behaviors = builtins.map (entry: entry.behavior) matching;
      reasons = builtins.map (entry: entry.reason) matching;
    in
    {
      present = matching != [ ];
      behavior = if behaviors == [ ] then "not-modeled" else builtins.head behaviors;
      reason = if reasons == [ ] then "no-matching-namespace-diagnostic" else builtins.head reasons;
      source = if matching == [ ] then "explicit-absence" else "namespaceDiagnostics";
      diagnostics = matching;
    };

  normalizeNamespaceAuthority = dnsPath: dns:
    let path = "${dnsPath}.namespaceAuthority";
    in
    builtins.map
      (entry:
        let
          entryPath = "${path}[*]";
          attrs = requireAttrs entryPath entry;
          ownerScope = requireString "${entryPath}.ownerScope" (attrs.ownerScope or null);
          namespaceOwner =
            if attrs ? namespaceOwner then
              requireString "${entryPath}.namespaceOwner" attrs.namespaceOwner
            else
              ownerScope;
          _ownerAliasMatch =
            if namespaceOwner != ownerScope then
              failInventory "${entryPath}.namespaceOwner" "must match ownerScope"
            else
              true;
        in
        builtins.seq _ownerAliasMatch ({
          namespace = requireString "${entryPath}.namespace" (attrs.namespace or null);
          inherit namespaceOwner ownerScope;
          requesterScopes = normalizeStringList "${entryPath}.requesterScopes" (attrs.requesterScopes or null);
          addressFamilies = normalizeStringList "${entryPath}.addressFamilies" (attrs.addressFamilies or null);
          fallbackBehavior = requireString "${entryPath}.fallbackBehavior" (attrs.fallbackBehavior or null);
        } // lib.optionalAttrs (attrs ? recordSources) {
          recordSources = normalizeStringList "${entryPath}.recordSources" attrs.recordSources;
        }))
      (requireList path (dns.namespaceAuthority or [ ]));

  normalizeLeaseNameScopes = dnsPath: dns: namespaceAuthority: namespaceFallback: namespaceDiagnostics:
    let
      path = "${dnsPath}.leaseNameScopes";
      authorityByNamespace = builtins.listToAttrs (
        builtins.map (entry: { name = entry.namespace; value = entry; }) namespaceAuthority
      );
      fallbackDecisions =
        if namespaceFallback == null then [ ] else namespaceFallback.decisions or [ ];
      deniedClassesFor = namespace: requesterScopes:
        let
          matching =
            builtins.filter
              (decision:
                (decision.namespace or null) == namespace
                && builtins.elem (decision.requesterScope or null) requesterScopes)
              fallbackDecisions;
        in
        lib.unique (builtins.concatMap (decision: decision.deniedClasses or decision.deniedRecordClasses or [ ]) matching);
      diagnosticsFor = namespace: recordName:
        builtins.filter
          (entry:
            (entry.namespace or null) == namespace
            && builtins.elem recordName (entry.recordNames or [ ]))
          namespaceDiagnostics;
    in
    builtins.map
      (entry:
        let
          entryPath = "${path}[*]";
          attrs = requireAttrs entryPath entry;
          namespace = requireString "${entryPath}.namespace" (attrs.namespace or null);
          recordSource = requireEnum "${entryPath}.recordSource" [ "dhcp4-lease" "dhcpv6-lease" ] (attrs.recordSource or null);
          ownerScope = requireString "${entryPath}.ownerScope" (attrs.ownerScope or null);
          namespaceOwner =
            if attrs ? namespaceOwner then
              requireString "${entryPath}.namespaceOwner" attrs.namespaceOwner
            else
              ownerScope;
          requesterScopes = normalizeStringList "${entryPath}.requesterScopes" (attrs.requesterScopes or null);
          addressFamily = requireEnum "${entryPath}.addressFamily" [ "ipv4" "ipv6" ] (attrs.addressFamily or null);
          expectedRecordClass = if addressFamily == "ipv4" then "A" else "AAAA";
          recordClass =
            if attrs ? recordClass then
              requireEnum "${entryPath}.recordClass" [ "A" "AAAA" ] attrs.recordClass
            else
              expectedRecordClass;
          authority = authorityByNamespace.${namespace} or null;
          fallbackBehavior =
            if attrs ? fallbackBehavior then
              requireString "${entryPath}.fallbackBehavior" attrs.fallbackBehavior
            else if authority != null then
              authority.fallbackBehavior
            else
              failInventory "${entryPath}.fallbackBehavior" "is required when namespaceAuthority does not define the lease namespace";
          deniedClasses =
            if attrs ? deniedClasses then
              normalizeStringList "${entryPath}.deniedClasses" attrs.deniedClasses
            else if attrs ? deniedRecordClasses then
              normalizeStringList "${entryPath}.deniedRecordClasses" attrs.deniedRecordClasses
            else
              deniedClassesFor namespace requesterScopes;
          recordDiagnostics = diagnosticsFor namespace (attrs.name or "");
          _ownerAliasMatch =
            if namespaceOwner != ownerScope then
              failInventory "${entryPath}.namespaceOwner" "must match ownerScope"
            else
              true;
          _authorityOwnerMatch =
            if authority != null && authority.namespaceOwner != namespaceOwner then
              failInventory "${entryPath}.namespaceOwner" "must match namespaceAuthority owner for namespace '${namespace}'"
            else
              true;
          _recordSourceFamilyMatch =
            if recordSource == "dhcp4-lease" && addressFamily != "ipv4" then
              failInventory "${entryPath}.addressFamily" "must be ipv4 for dhcp4-lease"
            else if recordSource == "dhcpv6-lease" && addressFamily != "ipv6" then
              failInventory "${entryPath}.addressFamily" "must be ipv6 for dhcpv6-lease"
            else
              true;
          _recordClassFamilyMatch =
            if recordClass != expectedRecordClass then
              failInventory "${entryPath}.recordClass" "must be ${expectedRecordClass} for ${addressFamily}"
            else
              true;
        in
        builtins.seq _ownerAliasMatch (builtins.seq _authorityOwnerMatch (builtins.seq _recordSourceFamilyMatch (builtins.seq _recordClassFamilyMatch ({
          name = requireString "${entryPath}.name" (attrs.name or null);
          inherit
            addressFamily
            deniedClasses
            fallbackBehavior
            namespace
            namespaceOwner
            ownerScope
            recordClass
            recordSource
            requesterScopes
            ;
          addresses = normalizeStringList "${entryPath}.addresses" (attrs.addresses or null);
          scopeDenialDiagnostic = requireString "${entryPath}.scopeDenialDiagnostic" (attrs.scopeDenialDiagnostic or null);
          conflict = normalizePredicate "${entryPath}.conflict" (attrs.conflict or null) (predicateFromDiagnostics [ "conflict" "duplicate-lease" ] recordDiagnostics);
          stale = normalizePredicate "${entryPath}.stale" (attrs.stale or null) (predicateFromDiagnostics [ "stale-lease" ] recordDiagnostics);
          revocation = normalizePredicate "${entryPath}.revocation" (attrs.revocation or null) {
            present = false;
            behavior = "not-modeled";
            reason = "no-modeled-lease-revocation";
            source = "explicit-absence";
            diagnostics = [ ];
          };
        } // lib.optionalAttrs (attrs ? deniedRequesterScopes) {
          deniedRequesterScopes = normalizeStringList "${entryPath}.deniedRequesterScopes" attrs.deniedRequesterScopes;
        } // lib.optionalAttrs (attrs ? allowedClasses) {
          allowedClasses = normalizeStringList "${entryPath}.allowedClasses" attrs.allowedClasses;
        })))))
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
