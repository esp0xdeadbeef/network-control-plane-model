{ lib
, common
, sitePath
, siteDns
, serviceDefinitions
, allowedRelations
,
}:

runtimeTargets:

let
  inherit (common) attrsOrEmpty failForwarding uniqueStrings;
  listOrEmpty = value: if builtins.isList value then value else [ ];
  recursive = attrsOrEmpty (siteDns.recursive or null);
  bindings = listOrEmpty (recursive.bindings or null);

  stripPrefixLength =
    value:
    if !(builtins.isString value) || value == "" then "" else builtins.head (lib.splitString "/" value);

  hostPrefix =
    value:
    let
      address = stripPrefixLength value;
    in
    if address == "" then
      null
    else
      "${address}/${if builtins.match ".*:.*" address == null then "32" else "128"}";

  targetNamesForNode =
    nodeName:
    builtins.filter
      (
        targetName: ((runtimeTargets.${targetName}.logicalNode or { }).name or null) == nodeName
      )
      (builtins.attrNames runtimeTargets);

  targetNameForNode =
    nodeName:
    let
      matches = targetNamesForNode nodeName;
    in
    if builtins.length matches == 1 then
      builtins.head matches
    else
      failForwarding sitePath "named DNS provider '${nodeName}' must resolve to exactly one runtime target";

  service =
    serviceName:
    if builtins.hasAttr serviceName serviceDefinitions then
      serviceDefinitions.${serviceName}
    else
      failForwarding "${sitePath}.dns" "named DNS service '${serviceName}' is absent from communicationContract.services";

  providerNodeForService =
    serviceName:
    let
      definition = service serviceName;
      providers = listOrEmpty (definition.providers or null);
    in
    if builtins.isString (definition.providerNode or null) then
      definition.providerNode
    else if builtins.length providers == 1 then
      builtins.head providers
    else
      failForwarding "${sitePath}.dns" "named DNS service '${serviceName}' must have exactly one provider node";

  endpointAddresses =
    targetName: families:
    let
      loopback = attrsOrEmpty (
        (attrsOrEmpty (runtimeTargets.${targetName}.effectiveRuntimeRealization or null)).loopback or null
      );
      ipv4 = stripPrefixLength (loopback.addr4 or loopback.ipv4 or "");
      ipv6 = stripPrefixLength (loopback.addr6 or loopback.ipv6 or "");
      values =
        lib.optional (builtins.elem "ipv4" families && ipv4 != "") ipv4
        ++ lib.optional (builtins.elem "ipv6" families && ipv6 != "") ipv6;
      missing =
        lib.optional (builtins.elem "ipv4" families && ipv4 == "") "ipv4"
        ++ lib.optional (builtins.elem "ipv6" families && ipv6 == "") "ipv6";
    in
    if missing == [ ] then
      values
    else
      failForwarding sitePath "named DNS provider lacks model-allocated family ${builtins.concatStringsSep "," missing}";

  tenantAddresses =
    targetName:
    let
      interfaces = attrsOrEmpty (
        (attrsOrEmpty (runtimeTargets.${targetName}.effectiveRuntimeRealization or null)).interfaces or null
      );
      tenantInterfaces = builtins.filter (iface: (iface.sourceKind or null) == "tenant") (
        builtins.attrValues interfaces
      );
    in
    uniqueStrings (
      lib.concatMap
        (iface: [
          (stripPrefixLength (iface.addr4 or ""))
          (stripPrefixLength (iface.addr6 or ""))
        ])
        tenantInterfaces
    );

  egressUplinksFor =
    serviceName:
    uniqueStrings (
      lib.concatMap
        (
          relation:
          let
            from = attrsOrEmpty (relation.from or null);
            to = attrsOrEmpty (relation.to or null);
          in
          if
            (relation.action or "allow") == "allow"
            && (relation.trafficType or null) == "dns"
            && (from.kind or null) == "service"
            && (from.name or null) == serviceName
            && (to.kind or null) == "external"
          then
            listOrEmpty (to.uplinks or null)
          else
            [ ]
        )
        allowedRelations
    );

  mergeDns =
    target: patch:
    let
      services = attrsOrEmpty (target.services or null);
      dns = attrsOrEmpty (services.dns or null);
    in
    target
    // {
      services = services // {
        dns = dns // patch;
      };
    };

  applyBinding =
    targets: binding:
    let
      upstream = attrsOrEmpty (binding.upstreamResolver or null);
      advertised = attrsOrEmpty (binding.advertisedResolver or null);
      coreServiceName = upstream.name or null;
      requesterServiceName = advertised.name or null;
      coreNodeName = upstream.node or (providerNodeForService coreServiceName);
      requesterNodeName = providerNodeForService requesterServiceName;
      coreTargetName = targetNameForNode coreNodeName;
      requesterTargetName = targetNameForNode requesterNodeName;
      families = listOrEmpty (binding.allowedAddressFamilies or null);
      endpoints = endpointAddresses coreTargetName families;
      requesterSources = tenantAddresses requesterTargetName;
      requesterHostPrefixes = builtins.filter (value: value != null) (map hostPrefix requesterSources);
      uplinks = egressUplinksFor coreServiceName;
      _egress =
        if uplinks == [ ] then
          failForwarding sitePath "named core DNS service '${coreServiceName}' has no explicit DNS egress selection"
        else
          true;
      accessTarget = targets.${requesterTargetName};
      accessDns = attrsOrEmpty ((attrsOrEmpty (accessTarget.services or null)).dns or null);
      accessRoles = attrsOrEmpty (accessDns.roles or null);
      accessRecursion = attrsOrEmpty (accessRoles.recursion or null);
      coreTarget = targets.${coreTargetName};
      coreDns = attrsOrEmpty ((attrsOrEmpty (coreTarget.services or null)).dns or null);
      coreRoles = attrsOrEmpty (coreDns.roles or null);
      coreRecursion = attrsOrEmpty (coreRoles.recursion or null);
      sourcePrefixes = builtins.filter (value: value != null) (
        map
          (
            address:
            let
              prefix = hostPrefix address;
            in
            if prefix == null then
              null
            else
              {
                family = if builtins.match ".*:.*" address == null then 4 else 6;
                inherit prefix;
              }
          )
          endpoints
      );
      preferredSources =
        lib.optionalAttrs (builtins.any (address: builtins.match ".*:.*" address == null) endpoints)
          {
            ipv4 = builtins.head (builtins.filter (address: builtins.match ".*:.*" address == null) endpoints);
          }
        // lib.optionalAttrs (builtins.any (address: builtins.match ".*:.*" address != null) endpoints) {
          ipv6 = builtins.head (builtins.filter (address: builtins.match ".*:.*" address != null) endpoints);
        };
      boundAccess = mergeDns accessTarget {
        forwarders = endpoints;
        outgoingInterfaces = requesterSources;
        upstreamResolvers = [
          {
            kind = "named-core-resolver";
            service = coreServiceName;
            node = coreNodeName;
            addresses = endpoints;
            addressAuthority = "model-allocated-service-prefix";
            returnBehavior = binding.returnBehavior or "symmetric";
          }
        ];
        roles = accessRoles // {
          recursion = accessRecursion // {
            outgoingInterfaces = requesterSources;
          };
        };
        coreResolverBinding = binding;
      };
      boundCoreBase = mergeDns coreTarget {
        listen = endpoints;
        allowFrom = uniqueStrings ((listOrEmpty (coreDns.allowFrom or null)) ++ requesterHostPrefixes);
        forwarders = [ ];
        outgoingInterfaces = [ ];
        recursionMode = (service coreServiceName).recursionMode or "iterative";
        egress = { inherit uplinks; };
        roles = coreRoles // {
          recursion = coreRecursion // {
            outgoingInterfaces = [ ];
          };
        };
      };
      boundCore = boundCoreBase // {
        runtimeOriginEgress = {
          enabled = true;
          source = "dns-service";
          inherit preferredSources sourcePrefixes uplinks;
        };
      };
    in
    builtins.seq _egress (
      targets
      // {
        ${requesterTargetName} = boundAccess;
        ${coreTargetName} = boundCore;
      }
    );
in
builtins.foldl' applyBinding runtimeTargets bindings
