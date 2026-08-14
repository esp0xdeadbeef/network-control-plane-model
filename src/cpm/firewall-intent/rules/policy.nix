{ common }:

{ endpointBindings
, relations
, services ? [ ]
, sharedServicePolicyAtoms ? [ ]
, trafficTypeMatches ? { }
, transitInterfaces
, runtimeOriginSourcePrefixes ? [ ]
, tenantPrefixOwners ? { }
}:
let
  endpointContext = import ./endpoint-context.nix { inherit common; } {
    inherit endpointBindings services transitInterfaces;
  };
  endpointSelection = import ./policy-endpoints.nix { inherit common endpointContext; };
  inherit (endpointContext) attrsOrEmpty listOrEmpty;
  inherit (endpointContext) serviceNamesForEndpoint serviceRecords uniqueStrings;
  inherit (endpointSelection) endpointIfaces endpointIfacesForPeerAccess;

  # Every tenant prefix owned by this site; used for tenant-set sources and as
  # the fallback when a relation source names no specific tenant.
  allTenantPrefixes =
    builtins.map
      (key:
        let
          parts = builtins.split "\\|" key;
          familyPart = builtins.elemAt parts 0;
          prefixPart = builtins.elemAt parts 2;
        in
        {
          family = if familyPart == "6" then 6 else 4;
          prefix = prefixPart;
        })
      (builtins.filter
        (key: (tenantPrefixOwners.${key}.kind or null) != "runtime-routed-prefix")
        (builtins.attrNames tenantPrefixOwners));

  # Tenant prefixes owned by a single access unit. The relation source tenant
  # name (e.g. "vlan2") maps to the owning access unit ("access-vlan2"), so a
  # tenant-scoped relation never admits another tenant's source prefixes.
  tenantPrefixesForTenant =
    tenantName:
    builtins.map
      (key:
        let
          parts = builtins.split "\\|" key;
          familyPart = builtins.elemAt parts 0;
          prefixPart = builtins.elemAt parts 2;
        in
        {
          family = if familyPart == "6" then 6 else 4;
          prefix = prefixPart;
        })
      (builtins.filter
        (key: (tenantPrefixOwners.${key}.owner or null) == "access-${tenantName}"
          && (tenantPrefixOwners.${key}.kind or null) != "runtime-routed-prefix")
        (builtins.attrNames tenantPrefixOwners));

  isNonEmptyString = value: builtins.isString value && value != "";

  relationId = relation:
    if builtins.isString (relation.id or null) && relation.id != "" then
      relation.id
    else if builtins.isString (relation.name or null) && relation.name != "" then
      relation.name
    else
      null;

  relationMatches = relation:
    if builtins.isList (relation.matches or null) then
      relation.matches
    else if builtins.isList (relation.match or null) then
      relation.match
    else
      trafficTypeMatches.${relation.trafficType or "any"} or [ ];

  discoverySurfaceMatch = surfaceRaw:
    let
      surface = attrsOrEmpty surfaceRaw;
      transport = surface.transport or null;
      port = surface.port or null;
    in
    if transport == "udp" && builtins.isInt port then
      {
        proto = "udp";
        family = "any";
        dports = [ port ];
      }
    else
      null;

  discoveryMatchesForAtom = atom:
    builtins.filter
      (match: match != null)
      (
        map discoverySurfaceMatch
          (listOrEmpty ((attrsOrEmpty (atom.discovery or null)).surfaces or null))
      );

  trafficTypeForAtom = atom: matches:
    let
      serviceName = atom.service or null;
      service =
        if isNonEmptyString serviceName then attrsOrEmpty (serviceRecords.${serviceName} or null) else { };
      serviceTrafficType = service.trafficType or null;
      serviceTrafficMatches =
        if isNonEmptyString serviceTrafficType then
          trafficTypeMatches.${serviceTrafficType} or [ ]
        else
          [ ];
    in
    if isNonEmptyString (atom.trafficType or null) then
      atom.trafficType
    else if isNonEmptyString serviceTrafficType && serviceTrafficMatches == matches then
      serviceTrafficType
    else
      "discovery";

  atomRequesters = atom:
    uniqueStrings (
      listOrEmpty (atom.requesterScopes or null)
      ++ listOrEmpty (atom.controllerScopes or null)
    );

  atomResponder = atom:
    if isNonEmptyString (atom.responderScope or null) then
      atom.responderScope
    else
      atom.receiverScope or null;

  sourcePrefixForAddress = family: address: {
    inherit family;
    prefix = address;
  };

  uniqueSourcePrefixes =
    prefixes:
    builtins.attrValues (
      builtins.listToAttrs (
        map
          (prefix: {
            name = "${builtins.toString (prefix.family or "")}|${prefix.prefix or ""}";
            value = prefix;
          })
          prefixes
      )
    );

  serviceSourcePrefixes =
    endpoint:
    uniqueSourcePrefixes (
      builtins.concatLists (
        map
          (serviceName:
            let
              service = attrsOrEmpty (serviceRecords.${serviceName} or null);
              providerEndpoints = listOrEmpty (service.providerEndpoints or null);
            in
            builtins.concatLists (
              map
                (providerEndpoint:
                  let
                    endpoint = attrsOrEmpty providerEndpoint;
                  in
                  map (sourcePrefixForAddress 4) (listOrEmpty (endpoint.ipv4 or null))
                  ++ map (sourcePrefixForAddress 6) (listOrEmpty (endpoint.ipv6 or null)))
                providerEndpoints
            ))
          (serviceNamesForEndpoint endpoint)
      )
    );

  withRelationSourceScope = relation: rule:
    let
      fromEndpoint = attrsOrEmpty (relation.from or null);
      prefixes =
        if (fromEndpoint.kind or null) == "service" then
          serviceSourcePrefixes fromEndpoint
        else if (fromEndpoint.kind or null) == "tenant" then
          tenantPrefixesForTenant (fromEndpoint.name or "")
        else if (fromEndpoint.kind or null) == "tenant-set" then
          allTenantPrefixes
        else
          [ ];
    in
    common.withSourcePrefixes rule prefixes;

  relationRules = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      action = if (relation.action or "allow") == "deny" then "deny" else "accept";
      id =
        let
          rawId = relationId relation;
        in
        if rawId == null then
          throw "FS-310-HDS-010-SDS-010-SMS-030: relationRules rejected rule with null relationId. Source relation must carry non-null id or name. Source: ${builtins.toJSON relationRaw}"
        else rawId;

      buildDirectionRules =
        { direction
        , fromEndpoint
        , toEndpoint
        , reverseSource ? false
        , stateful ? false
        }:
        let
          fromIfaces = endpointIfaces relation fromEndpoint toEndpoint;
          relationForSource =
            if reverseSource then
              relation // {
                from = attrsOrEmpty fromEndpoint;
                to = attrsOrEmpty toEndpoint;
              }
            else
              relation;
          ruleEndpointFrom = attrsOrEmpty fromEndpoint;
          ruleEndpointTo = attrsOrEmpty toEndpoint;
        in
        builtins.concatLists (
          map
            (fromIface:
              let
                toIfaces =
                  endpointIfacesForPeerAccess relation toEndpoint fromEndpoint (common.laneAccess fromIface);
              in
              map
                (toIface:
                  withRelationSourceScope relationForSource {
                    inherit action;
                    relationId = id;
                    comment = id;
                    priority = relation.priority or null;
                    trafficType = relation.trafficType or "any";
                    inherit direction;
                    matches = relationMatches relation;
                    from = ruleEndpointFrom;
                    to = ruleEndpointTo;
                    relationCardinality = {
                      unit = "policy-router-forwarding-rule";
                      decomposition = "decomposed-by-policy-interface-scope";
                      decomposed = true;
                    };
                    fromInterface = fromIface.runtimeIfName;
                    toInterface = toIface.runtimeIfName;
                    applyTcpMssClamp = false;
                  }
                  // common.relationHandoff {
                    relationId = id;
                    inherit action direction fromIface toIface;
                    policyPoint = "policy-router";
                  }
                  // (if builtins.isAttrs (relation.intent or null) then { intent = relation.intent; } else { })
                  // (if isNonEmptyString (relation.comment or null) then { comment = relation.comment; } else { })
                  // (
                    # FS-180-HDS-010-SDS-010-SMS-040: a symmetric return is
                    # bounded stateful reply traffic, never independently
                    # initiated reverse new-flow authority. Mark the reverse
                    # rule with an established,related connection-state
                    # constraint so target-native realization emits a stateful
                    # return rather than a state-unqualified reverse accept.
                    if stateful then
                      {
                        connectionState = "established,related";
                        returnRule = true;
                      }
                    else
                      { }
                  ))
                toIfaces)
            fromIfaces
        );

      forwardRules = buildDirectionRules {
        direction = "relation-forward";
        fromEndpoint = relation.from or null;
        toEndpoint = relation.to or null;
      };

      reverseRules =
        if (relation.returnBehavior or null) == "symmetric" then
          buildDirectionRules {
            direction = "relation-reverse";
            fromEndpoint = relation.to or null;
            toEndpoint = relation.from or null;
            reverseSource = true;
            stateful = true;
          }
        else
          [ ];
    in
    builtins.seq id (forwardRules ++ reverseRules);

  sharedDiscoveryPolicyRules = atomRaw:
    let
      atom = attrsOrEmpty atomRaw;
      id = atom.id or null;
      matches = discoveryMatchesForAtom atom;
      responder = atomResponder atom;
      requesters = atomRequesters atom;
    in
    if !isNonEmptyString id || !isNonEmptyString responder || matches == [ ] then
      [ ]
    else
      builtins.concatLists (
        map
          (requester:
            relationRules {
              action = "allow";
              from = {
                kind = "tenant";
                name = requester;
              };
              id = id;
              priority = atom.priority or 119;
              to = {
                kind = "tenant";
                name = responder;
              };
              trafficType = trafficTypeForAtom atom matches;
              inherit matches;
              intent = {
                kind = "shared-service-discovery-policy";
                policyAtomId = id;
                service = atom.service or null;
                serviceClass = atom.serviceClass or null;
                sms = atom.sms or null;
                source = attrsOrEmpty (atom.source or null);
              };
              comment = "shared-service-discovery-policy:${id}";
            })
          requesters
      );
in
let
  # SN2: duplicate relationId collision detection
  relIds = builtins.filter (id: id != null) (map (r: relationId (attrsOrEmpty r)) (listOrEmpty relations));
  idGroups = builtins.groupBy (id: id) relIds;
  duplicateIds = builtins.filter (g: (builtins.length idGroups."${g}") > 1) (builtins.attrNames idGroups);
in
if duplicateIds != [ ] then
  throw "FS-310-HDS-010-SDS-010-SMS-030: duplicate relationId collision detected. Duplicate IDs: ${builtins.concatStringsSep ", " duplicateIds}. Each relation must have a unique id."
else
builtins.concatLists (map relationRules (listOrEmpty relations))
++ builtins.concatLists (map sharedDiscoveryPolicyRules (listOrEmpty sharedServicePolicyAtoms))
++ common.runtimeOriginDefaultForwardRulesWith {
  inherit runtimeOriginSourcePrefixes;
  interfaces = transitInterfaces;
  isIngressIface = iface: common.laneKind iface == "access";
  isDefaultIface = iface: common.laneKind iface == "access-uplink";
}
