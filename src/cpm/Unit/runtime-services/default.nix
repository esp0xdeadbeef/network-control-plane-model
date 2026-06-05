{ lib
, helpers
, sitePath
, attachments
, attrsOrEmpty
, failInventory
, policyDerivedDnsAllowFromForListeners
, policyDerivedDnsAllowedClassesForListeners
, policyDerivedDnsAllowedClassesForTenants
, policyDerivedDnsDirectEgressBlockedTenants
, policyDerivedDnsDirectEgressBlockedForListeners
, policyDerivedDnsDirectEgressBlockedForTenants
, policyDerivedDnsForwardersForListeners
, policyDerivedDnsForwardersForTenants
, uniqueStrings
,
}:

let
  inherit (helpers)
    isNonEmptyString
    requireAttrs
    requireString
    requireList
    requireStringList
    sortedNames
    ;

  dns = import ./dns.nix { inherit lib helpers failInventory; };
  mdns = import ./mdns.nix { inherit lib helpers failInventory; };
  inherit (dns) normalizeDnsService;
  inherit (mdns) normalizeMdnsService;

  orderedUniqueStrings =
    values:
    builtins.foldl'
      (
        acc: value:
        if isNonEmptyString value && !(builtins.elem value acc) then acc ++ [ value ] else acc
      )
      [ ]
      values;

  stripPrefixLength = value:
    if !(isNonEmptyString value) then "" else builtins.head (lib.splitString "/" value);

  normalizeRuntimeServices = targetDef:
    let
      servicesPath = "${targetDef.nodePath}.services";
      services = requireAttrs servicesPath (targetDef.node.services or null);
      requireBool = path: value:
        if builtins.isBool value then value else failInventory path "must be a boolean";
      requirePositiveInt = path: value:
        if builtins.isInt value && value > 0 then value else failInventory path "must be a positive integer";
      normalizeCredentials = servicePath: service:
        if service ? credentials then
          let
            credentialsPath = "${servicePath}.credentials";
            credentials = requireAttrs credentialsPath service.credentials;
            username = credentials.username or null;
            password = credentials.password or null;
            usernameFile = credentials.usernameFile or null;
            passwordFile = credentials.passwordFile or null;
            hasInline = username != null || password != null;
            hasFiles = usernameFile != null || passwordFile != null;
            _mode =
              if hasInline && hasFiles then
                failInventory credentialsPath "must use either inline username/password or usernameFile/passwordFile, not both"
              else if hasFiles then
                true
              else if hasInline then
                true
              else
                failInventory credentialsPath "must define username/password or usernameFile/passwordFile";
          in
          builtins.seq _mode {
            credentials = (
              if hasFiles then
                {
                  usernameFile = requireString "${credentialsPath}.usernameFile" usernameFile;
                  passwordFile = requireString "${credentialsPath}.passwordFile" passwordFile;
                }
              else
                {
                  username = requireString "${credentialsPath}.username" username;
                  password = requireString "${credentialsPath}.password" password;
                }
            ) // lib.optionalAttrs (credentials ? labOnly) {
              labOnly = requireBool "${credentialsPath}.labOnly" credentials.labOnly;
            };
          }
        else
          { };
      normalizePPPoEClient = pppoePath: client:
        let
          clientPath = "${pppoePath}.client";
          clientAttrs = requireAttrs clientPath client;
        in
        {
          interface = requireString "${clientPath}.interface" (clientAttrs.interface or null);
          runtimeInterface = requireString "${clientPath}.runtimeInterface" (clientAttrs.runtimeInterface or null);
          defaultRoute = requireBool "${clientPath}.defaultRoute" (clientAttrs.defaultRoute or null);
          usePeerDns = requireBool "${clientPath}.usePeerDns" (clientAttrs.usePeerDns or null);
          mtu = requirePositiveInt "${clientPath}.mtu" (clientAttrs.mtu or null);
        } // normalizeCredentials clientPath clientAttrs;
      normalizePPPoEServer = pppoePath: server:
        let
          serverPath = "${pppoePath}.server";
          serverAttrs = requireAttrs serverPath server;
        in
        {
          interface = requireString "${serverPath}.interface" (serverAttrs.interface or null);
          implementation = requireString "${serverPath}.implementation" (serverAttrs.implementation or null);
          providerAddress = requireString "${serverPath}.providerAddress" (serverAttrs.providerAddress or null);
          customerAddress = requireString "${serverPath}.customerAddress" (serverAttrs.customerAddress or null);
          maxSessions = requirePositiveInt "${serverPath}.maxSessions" (serverAttrs.maxSessions or null);
          mtu = requirePositiveInt "${serverPath}.mtu" (serverAttrs.mtu or null);
        } // normalizeCredentials serverPath serverAttrs;
      normalizePPPoEService = servicesPath: pppoeValue:
        let
          pppoePath = "${servicesPath}.pppoe";
          pppoe = requireAttrs pppoePath pppoeValue;
          serviceNames = sortedNames pppoe;
          allowedServiceNames = [ "client" "server" ];
          unexpectedServiceNames = builtins.filter (name: !(builtins.elem name allowedServiceNames)) serviceNames;
          roleCount =
            (if pppoe ? client then 1 else 0)
            + (if pppoe ? server then 1 else 0);
          _unexpected =
            if unexpectedServiceNames != [ ] then
              failInventory pppoePath "must contain only 'client' or 'server' roles"
            else
              true;
          _roleCount =
            if roleCount == 1 then
              true
            else
              failInventory pppoePath "must define exactly one of 'client' or 'server'"
            ;
        in
        builtins.seq _unexpected (
          builtins.seq _roleCount (
            lib.optionalAttrs (pppoe ? client) { client = normalizePPPoEClient pppoePath pppoe.client; }
            // lib.optionalAttrs (pppoe ? server) { server = normalizePPPoEServer pppoePath pppoe.server; }
          )
        );
    in
    builtins.listToAttrs (
      builtins.map
        (serviceName: {
          name = serviceName;
          value =
            if serviceName == "dns" then
              normalizeDnsService servicesPath services.${serviceName}
            else if serviceName == "mdns" then
              normalizeMdnsService servicesPath services.${serviceName}
            else if serviceName == "pppoe" then
              normalizePPPoEService servicesPath services.${serviceName}
            else
              services.${serviceName};
        })
        (sortedNames services)
    );

  tenantAttachmentsForNode = nodePath: nodeName: nodeAttrs:
    uniqueStrings (
      (builtins.map
        (attachment:
          let attachmentAttrs = requireAttrs "${sitePath}.attachments[*]" attachment;
          in
          if (attachmentAttrs.kind or null) == "tenant" && (attachmentAttrs.unit or null) == nodeName && isNonEmptyString (attachmentAttrs.name or null) then
            attachmentAttrs.name
          else
            "")
        attachments)
      ++ (
        if builtins.isList (nodeAttrs.attachments or null) then
          builtins.map
            (attachment:
              let attachmentAttrs = requireAttrs "${nodePath}.attachments[*]" attachment;
              in
              if (attachmentAttrs.kind or null) == "tenant" && isNonEmptyString (attachmentAttrs.name or null) then attachmentAttrs.name else "")
            nodeAttrs.attachments
        else
          [ ]
      )
    );

  resolveRuntimeServices = import ./resolve.nix {
    inherit
      lib
      attrsOrEmpty
      requireStringList
      uniqueStrings
      orderedUniqueStrings
      stripPrefixLength
      tenantAttachmentsForNode
      policyDerivedDnsAllowFromForListeners
      policyDerivedDnsAllowedClassesForListeners
      policyDerivedDnsAllowedClassesForTenants
      policyDerivedDnsDirectEgressBlockedTenants
      policyDerivedDnsDirectEgressBlockedForListeners
      policyDerivedDnsDirectEgressBlockedForTenants
      policyDerivedDnsForwardersForListeners
      policyDerivedDnsForwardersForTenants
      normalizeRuntimeServices
      ;
  };

in
{
  inherit
    resolveRuntimeServices
    tenantAttachmentsForNode
    ;
}
