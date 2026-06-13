{ lib
, helpers
, inventory ? { }
, secretPlatformSubstrate ? "nixos"
}:

let
  inherit (helpers)
    forceAll
    isNonEmptyString
    requireAttrs
    requireString
    hasAttr
    ;

  failInventory = path: message:
    throw "inventory.nix update required: ${path}: ${message}";

  # Gather secret inputs from inventory
  secretDeclarations =
    if builtins.isList (inventory.secretDeclarations or null) && inventory.secretDeclarations != [ ]
    then inventory.secretDeclarations
    else [ ];

  secretSources =
    if builtins.isList (inventory.secretSources or null) && inventory.secretSources != [ ]
    then inventory.secretSources
    else [ ];

  sourceBindings =
    if builtins.isList (inventory.sourceBindings or null) && inventory.sourceBindings != [ ]
    then inventory.sourceBindings
    else [ ];

  # Platform-specific mapping for secret paths
  platformSecretBase = substrate:
    if substrate == "nixos" || substrate == "clab" then
      "/run/secrets"
    else
      null;

  # Validate a single source record's runtimePath is an abstract reference name
  # (no leading /) per FS-820-HDS-010-SDS-010-SMS-030
  validSource = source:
    let
      sourceId = source.id or "unknown";
      sourcePath = "secretSources.${sourceId}";
      ref = requireAttrs "${sourcePath}.reference" (source.reference or { });
      rtPath = ref.runtimePath or "";
    in
    if !(isNonEmptyString rtPath) then
      failInventory "${sourcePath}.reference.runtimePath"
        "FS-820-HDS-010-SDS-010-SMS-030: runtimePath must be an abstract reference name (non-empty string)"
    else if builtins.substring 0 1 rtPath == "/" then
      failInventory "${sourcePath}.reference.runtimePath"
        "FS-820-HDS-010-SDS-010-SMS-030: runtimePath must be an abstract reference name (no leading /), got fixed path '${rtPath}'"
    else
      source;

  # Map an abstract reference name to a deployment-platform path
  mapRuntimePath = substrate: source:
    let
      base = platformSecretBase substrate;
      ref = source.reference or { };
      rtPath = ref.runtimePath or "";
      sourceId = source.id or "unknown";
    in
    if base == null then
      failInventory "secretSources.${sourceId}.reference.runtimePath"
        "FS-820-HDS-010-SDS-010-SMS-030: unknown target substrate '${substrate}' for secret path mapping; known substrates: nixos, clab"
    else
      ref // {
        mediatedRuntimePath = "${base}/${rtPath}";
      };

  # Validate all sources then produce mediated versions
  validatedSources =
    let
      _forced = forceAll (builtins.map validSource secretSources);
    in
    builtins.seq _forced (
      builtins.map (source:
        source // {
          reference = mapRuntimePath secretPlatformSubstrate source;
        }
      ) secretSources
    );

  # Build a lookup from declaration ID to declaration record
  declLookup =
    builtins.listToAttrs (
      builtins.map (decl: {
        name = decl.id;
        value = decl;
      }) secretDeclarations
    );

  # Build a lookup from source ID to source record
  sourceLookup =
    builtins.listToAttrs (
      builtins.map (src: {
        name = src.id;
        value = src;
      }) validatedSources
    );

  # ── FS-820-HDS-010-SDS-010-SMS-030: Policy boundary classification ────────

  # Classification enumeration: fields that when present in source binding
  # metadata indicate unauthorized policy creation (SN1)
  policyBearingFields = [
    "allowRoute"
    "allowFirewall"
    "allowDns"
    "allowPublicIngress"
    "allowTenantReachability"
    "allowNetworkBehavior"
  ];

  # Classification enumeration: fields that when present in source binding
  # metadata indicate unauthorized trust boundary creation (SN2)
  trustBoundaryFields = [
    "trustAnchor"
  ];

  # Predicate: check if a source binding is policy-neutral (no forbidden metadata fields)
  isBindingPolicyNeutral = binding:
    let
      meta = binding.metadata or { };
    in
    !(builtins.any (f: hasAttr f meta) (policyBearingFields ++ trustBoundaryFields));

  # Scan a source binding for policy-bearing metadata fields (SN1)
  policyBoundaryDiagnosticForBinding = binding:
    let
      meta = binding.metadata or { };
      bindingId = binding.id or "unknown";
      declId = binding.declarationId or "unknown";

      # Find all policy-bearing fields present in metadata
      foundFields = builtins.filter (f: hasAttr f meta) policyBearingFields;
    in
    if foundFields != [ ] then
      {
        bindingId = bindingId;
        declarationId = declId;
        diagnosticName = "POLICY_BEARING_SOURCE_BINDING";
        policyFields = foundFields;
        diagnostic = "FS-820-HDS-010-SDS-010-SMS-030 SN1: source binding '${bindingId}' contains policy-bearing metadata field(s) ${
          builtins.concatStringsSep ", " foundFields
        }; source bindings are credential realization data only and shall not create network policy";
        gampIds = [
          "FS-820-HDS-010-SDS-010-SMS-030"
        ];
      }
    else
      null;

  # Scan a source binding for trust-boundary metadata fields (SN2)
  trustBoundaryDiagnosticForBinding = binding:
    let
      meta = binding.metadata or { };
      bindingId = binding.id or "unknown";
      declId = binding.declarationId or "unknown";
      foundFields = builtins.filter (f: hasAttr f meta) trustBoundaryFields;
    in
    if foundFields != [ ] then
      let
        trustAnchor = meta.trustAnchor or { };
        affectedTenant =
          if hasAttr "tenant" trustAnchor
          then trustAnchor.tenant
          else "unknown";
      in
      {
        bindingId = bindingId;
        declarationId = declId;
        diagnosticName = "TRUST_BOUNDARY_SOURCE_BINDING";
        trustFields = foundFields;
        affectedTenant = affectedTenant;
        diagnostic = "FS-820-HDS-010-SDS-010-SMS-030 SN2: source binding '${bindingId}' contains trust-boundary metadata field(s) ${
          builtins.concatStringsSep ", " foundFields
        } (affected tenant '${affectedTenant}'); source bindings are credential realization data only and shall not create trust boundaries";
        gampIds = [
          "FS-820-HDS-010-SDS-010-SMS-030"
        ];
      }
    else
      null;

  policyBoundaryDiagnostics =
    builtins.filter (d: d != null) (builtins.map policyBoundaryDiagnosticForBinding sourceBindings);

  trustBoundaryDiagnostics =
    builtins.filter (d: d != null) (builtins.map trustBoundaryDiagnosticForBinding sourceBindings);

  # Filter source bindings to only policy-neutral bindings for downstream consumption
  policyNeutralBindings = builtins.filter isBindingPolicyNeutral sourceBindings;

  # Build scoped delivery records from source bindings per FS-840-HDS-010-SDS-010-SMS-010
  # Only process policy-neutral bindings per FS-820-SMS-030
  deliveryRecordForBinding = binding:
    let
      decl = declLookup.${binding.declarationId} or null;
      src = sourceLookup.${binding.sourceId} or null;
      consumer = if decl != null && hasAttr "consumer" decl then decl.consumer else { };
      site = if decl != null && hasAttr "site" decl then decl.site else null;
      host = if decl != null && hasAttr "host" decl then decl.host else null;
      service = if decl != null && hasAttr "purpose" decl then decl.purpose else null;
      tenant = if decl != null && hasAttr "tenant" decl then decl.tenant else null;
      mediatedPath =
        if src != null && hasAttr "reference" src && hasAttr "mediatedRuntimePath" src.reference
        then src.reference.mediatedRuntimePath
        else null;
    in
    {
      deliveryId = "${binding.id}-delivery";
      bindingId = binding.id;
      declarationId = binding.declarationId;
      sourceId = binding.sourceId;
      deliveryScope = {
        inherit site tenant host service consumer;
      };
      authorizedScope =
        if decl != null && hasAttr "authorizedScope" decl
        then decl.authorizedScope
        else null;
      mediatedPath = mediatedPath;
      sourceClass = binding.sourceClass or (if src != null then src.sourceClass else null);
      gampIds = [
        "FS-840-HDS-010-SDS-010-SMS-010"
      ];
    };

  deliveryRecords = builtins.map deliveryRecordForBinding policyNeutralBindings;

  # Build readiness diagnostics per FS-840-HDS-010-SDS-010-SMS-030
  # Reject when material is not supplied by source (e.g., reference-only secrets
  # require deployment to actually place the material)
  readinessDiagnosticForRecord = record:
    let
      src = sourceLookup.${record.sourceId} or null;
      materialAccess = if src != null then src.materialAccess or "unknown" else "unknown";
      consumer = record.deliveryScope.consumer or { };
    in
    if materialAccess == "not-supplied-by-source-record" then
      {
        deliveryId = record.deliveryId;
        consumer = consumer;
        scope = record.deliveryScope;
        mediatedPath = record.mediatedPath;
        materialAccess = materialAccess;
        diagnostic = "FS-840-HDS-010-SDS-010-SMS-030: secret material not supplied by source record; deployment must provide material before service readiness is claimed";
        gampIds = [
          "FS-840-HDS-010-SDS-010-SMS-030"
        ];
      }
    else
      null;

  # Validate authorizedConsumer is present and non-empty per FS-840-HDS-010-SDS-010-SMS-010 SN3
  authorizedConsumerDiagnosticForRecord = record:
    let
      consumer = record.deliveryScope.consumer or { };
      consumerKind = consumer.kind or "";
      consumerNode = consumer.node or "";
      consumerName = consumer.name or "";
    in
    if consumer == { } || consumer == null
       || !(isNonEmptyString consumerKind)
       || !(isNonEmptyString consumerNode)
       || !(isNonEmptyString consumerName) then
      {
        deliveryId = record.deliveryId;
        consumer = consumer;
        scope = record.deliveryScope;
        diagnosticName = "runtime-missing-authorized-consumer";
        diagnostic = "FS-840-HDS-010-SDS-010-SMS-010 SN3: authorizedConsumer is missing, null, or has empty required fields (kind, node, name)";
        gampIds = [
          "FS-840-HDS-010-SDS-010-SMS-010"
        ];
      }
    else
      null;

  # Validate delivery tenant is within authorizedScope per FS-840-HDS-010-SDS-010-SMS-030 SN2
  # Reject when a delivery record includes a secret for a tenant not in the authorized scope
  overBroadDeliveryDiagnosticForRecord = record:
    let
      authScope = record.authorizedScope or null;
      deliveryTenant = record.deliveryScope.tenant or null;
    in
    if authScope != null && deliveryTenant != null && !(builtins.elem deliveryTenant authScope) then
      {
        deliveryId = record.deliveryId;
        tenant = deliveryTenant;
        authorizedScope = authScope;
        diagnosticName = "runtime-over-broad-secret-delivery";
        diagnostic = "FS-840-HDS-010-SDS-010-SMS-030 SN2: secret delivery includes tenant '${deliveryTenant}' not in authorizedScope ${builtins.toJSON authScope}";
        gampIds = [
          "FS-840-HDS-010-SDS-010-SMS-030"
        ];
      }
    else
      null;

  readinessDiagnostics =
    builtins.filter (d: d != null) (builtins.map readinessDiagnosticForRecord deliveryRecords);

  # Validate consumerRole matches host's modeled role per FS-840-HDS-010-SDS-010-SMS-010 SN2
  consumerRoleMismatchDiagnosticForRecord = record:
    let
      consumer = record.deliveryScope.consumer or { };
      consumerRole = consumer.role or null;
      hostName = record.deliveryScope.host or null;
      hostDef =
        if hostName != null
           && inventory ? deployment
           && inventory.deployment ? hosts
           && hasAttr hostName inventory.deployment.hosts
        then inventory.deployment.hosts.${hostName}
        else null;
      hostRole = if hostDef != null && hasAttr "role" hostDef then hostDef.role else null;
    in
    if consumerRole != null && hostRole != null && !(isNonEmptyString consumerRole) then
      # consumerRole present but empty → treat as mismatch with any host role
      {
        deliveryId = record.deliveryId;
        consumer = consumer;
        scope = record.deliveryScope;
        host = hostName;
        consumerRole = consumerRole;
        hostRole = hostRole;
        diagnosticName = "runtime-consumer-role-mismatch";
        diagnostic = "FS-840-HDS-010-SDS-010-SMS-010 SN2: consumerRole is empty string for host '${hostName}' (expected role '${hostRole}')";
        gampIds = [
          "FS-840-HDS-010-SDS-010-SMS-010"
        ];
      }
    else if consumerRole != null && hostRole != null && consumerRole != hostRole then
      {
        deliveryId = record.deliveryId;
        consumer = consumer;
        scope = record.deliveryScope;
        host = hostName;
        consumerRole = consumerRole;
        hostRole = hostRole;
        diagnosticName = "runtime-consumer-role-mismatch";
        diagnostic = "FS-840-HDS-010-SDS-010-SMS-010 SN2: consumerRole '${consumerRole}' does not match host '${hostName}' expected role '${hostRole}'";
        gampIds = [
          "FS-840-HDS-010-SDS-010-SMS-010"
        ];
      }
    else
      null;

  authorizedConsumerDiagnostics =
    builtins.filter (d: d != null) (builtins.map authorizedConsumerDiagnosticForRecord deliveryRecords);

  consumerRoleMismatchDiagnostics =
    builtins.filter (d: d != null) (builtins.map consumerRoleMismatchDiagnosticForRecord deliveryRecords);

  overBroadDeliveryDiagnostics =
    builtins.filter (d: d != null) (builtins.map overBroadDeliveryDiagnosticForRecord deliveryRecords);

  # Helper: map a single credential file name from abstract to platform path
  # Returns the mapped path or the original if already a platform path
  mapCredentialPath = substrate: path:
    if !(isNonEmptyString path) then
      path
    else if builtins.substring 0 1 path == "/" then
      # Already a full filesystem path; this should not occur if the
      # inventory is using abstract names, but tolerate it.
      path
    else
      let
        base = platformSecretBase substrate;
      in
      if base == null then
        path
      else
        "${base}/${path}";

  # Mediate credential file paths in a single services attribute set
  mediateServiceCredentials = substrate: services:
    let
      pppoe = if builtins.isAttrs (services.pppoe or null) then services.pppoe else { };
      mediateRole = role: roleAttrs:
        let
          creds = if builtins.isAttrs (roleAttrs.credentials or null) then roleAttrs.credentials else { };
          mappedCreds = creds;
          mappedCredsWithUsername =
            if hasAttr "usernameFile" creds then
              mappedCreds // {
                usernameFile = mapCredentialPath substrate creds.usernameFile;
              }
            else
              mappedCreds;
          mappedCredsFinal =
            if hasAttr "passwordFile" creds then
              mappedCredsWithUsername // {
                passwordFile = mapCredentialPath substrate creds.passwordFile;
              }
            else
              mappedCredsWithUsername;
        in
        if mappedCredsFinal != { } then
          roleAttrs // { credentials = mappedCredsFinal; }
        else
          roleAttrs;
      mediatedPppoe =
        pppoe
        // lib.optionalAttrs (hasAttr "client" pppoe) {
          client = mediateRole "client" pppoe.client;
        }
        // lib.optionalAttrs (hasAttr "server" pppoe) {
          server = mediateRole "server" pppoe.server;
        };
    in
    if pppoe != { } then
      services // { pppoe = mediatedPppoe; }
    else
      services;

  # Walk the CPM data tree and mediate credential paths in all runtime targets
  mediateCpmData = substrate: cpmData:
    builtins.mapAttrs (_enterpriseName: enterpriseData:
      builtins.mapAttrs (_siteName: siteData:
        if hasAttr "runtimeTargets" siteData then
          siteData // {
            runtimeTargets = builtins.mapAttrs (_targetName: targetData:
              if hasAttr "services" targetData then
                targetData // {
                  services = mediateServiceCredentials substrate (targetData.services or { });
                }
              else
                targetData
            ) siteData.runtimeTargets;
          }
        else
          siteData
      ) enterpriseData
    ) cpmData;
in
{
  # Processed secret arrays
  secretDeclarations = secretDeclarations;
  secretSources = validatedSources;
  sourceBindings = sourceBindings;

  # Scoped delivery records per FS-840-SMS-010
  secretDeliveryRecords = deliveryRecords;

  # Readiness state per FS-840-SMS-030
  secretReadiness = {
    inherit readinessDiagnostics;
    allMaterialReady = readinessDiagnostics == [ ];
  };

  # Authorized consumer validation per FS-840-SMS-010 SN3
  # Consumer role mismatch per FS-840-SMS-010 SN2
  # Over-broad delivery guard per FS-840-SMS-030 SN2
  secretAuthorization = {
    inherit authorizedConsumerDiagnostics consumerRoleMismatchDiagnostics overBroadDeliveryDiagnostics;
    allAuthorized = authorizedConsumerDiagnostics == [ ] && consumerRoleMismatchDiagnostics == [ ] && overBroadDeliveryDiagnostics == [ ];
  };

  # Policy boundary validation per FS-820-SMS-030
  # SN1: policy-field classification (POLICY_BEARING_SOURCE_BINDING)
  # SN2: trust-boundary classification (TRUST_BOUNDARY_SOURCE_BINDING)
  secretPolicyBoundary = {
    inherit policyBoundaryDiagnostics trustBoundaryDiagnostics;
    allPolicyNeutral = policyBoundaryDiagnostics == [ ] && trustBoundaryDiagnostics == [ ];
  };

  # Utility to mediate credential paths in CPM output data tree
  mediateCredentialPaths = mediateCpmData secretPlatformSubstrate;

  # Pass substrate for downstream use
  inherit secretPlatformSubstrate;
}
