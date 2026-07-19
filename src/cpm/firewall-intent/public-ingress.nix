{ helpers, lib, ipam }:

let
  inherit (helpers) isNonEmptyString;
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  listOrEmpty = value: if builtins.isList value then value else [ ];
  uniqueStrings = values:
    builtins.attrNames (
      builtins.listToAttrs (
        map (value: { name = value; value = true; })
          (builtins.filter isNonEmptyString values)
      )
    );

  relationId = relation:
    if isNonEmptyString (relation.id or null) then relation.id
    else if isNonEmptyString (relation.name or null) then relation.name
    else null;

  externalNames = endpoint:
    let value = attrsOrEmpty endpoint;
    in
    if (value.kind or null) != "external" then [ ]
    else uniqueStrings (
      listOrEmpty (value.uplinks or null)
      ++ (if isNonEmptyString (value.name or null) then [ value.name ] else [ ])
    );

  stripCidr = value:
    if !isNonEmptyString value then null
    else builtins.head (builtins.filter builtins.isString (builtins.split "/" value));

  p2pPeer4 = cidr:
    let
      parts = if builtins.isString cidr then builtins.filter builtins.isString (builtins.split "/" cidr) else [ ];
      address = if parts == [ ] then "" else builtins.head parts;
      prefixLength = if builtins.length parts == 2 then builtins.elemAt parts 1 else "";
      octets = builtins.filter builtins.isString (builtins.split "\\." address);
      valid =
        prefixLength == "31"
        && builtins.length octets == 4
        && builtins.all (octet: builtins.match "[0-9]+" octet != null) octets;
      numbers = if valid then map builtins.fromJSON octets else [ ];
      last = if valid then builtins.elemAt numbers 3 else 0;
      peerLast = if builtins.bitAnd last 1 == 0 then last + 1 else last - 1;
    in
    if !valid || !builtins.all (number: number >= 0 && number <= 255) numbers then
      null
    else
      builtins.concatStringsSep "." (
        builtins.genList
          (index: builtins.toString (if index == 3 then peerLast else builtins.elemAt numbers index))
          4
      );

  requireOne = context: values:
    if builtins.length values == 1 then builtins.head values
    else throw "public ingress ${context} must resolve exactly once; resolved ${builtins.toString (builtins.length values)} records";

  serviceIndex = services:
    builtins.listToAttrs (
      map (service: { name = service.name; value = service; })
        (builtins.filter
          (service: builtins.isAttrs service && isNonEmptyString (service.name or null))
          (listOrEmpty services))
    );

  targetAccessNodesFor = policyEndpointBindings: service:
    let
      tenantBindings = attrsOrEmpty ((attrsOrEmpty policyEndpointBindings).tenants or null);
    in
    uniqueStrings (
      builtins.concatMap
        (tenant:
          if !(builtins.hasAttr tenant tenantBindings) then [ ]
          else map
            (binding: (attrsOrEmpty binding).logicalNode or null)
            (listOrEmpty (tenantBindings.${tenant}.runtimeBindings or null)))
        (listOrEmpty (service.providerTenants or null))
    );

  endpointAddresses4 = endpoint:
    uniqueStrings (listOrEmpty ((attrsOrEmpty endpoint).ipv4 or null));

  endpointAddresses6 = endpoint:
    uniqueStrings (listOrEmpty ((attrsOrEmpty endpoint).ipv6 or null));

  p2pPeer6 = cidr:
    let
      parsed = if builtins.isString cidr then ipam.splitCIDR cidr else null;
      address = if parsed != null && parsed.prefixLen == 127 then ipam.parseIPv6 parsed.addr else null;
      peer =
        if address == null then
          null
        else
          builtins.genList
            (index:
              if index != 7 then
                builtins.elemAt address index
              else if lib.mod (builtins.elemAt address index) 2 == 0 then
                (builtins.elemAt address index) + 1
              else
                (builtins.elemAt address index) - 1)
            8;
    in
    if peer == null then null else ipam.renderIPv6 peer;

  interfaceIdentifier64 = address:
    let
      parsed = if builtins.isString address then ipam.parseIPv6 address else null;
      identifier =
        if parsed == null then
          null
        else
          builtins.genList
            (index: if index < 4 then 0 else builtins.elemAt parsed index)
            8;
    in
    if identifier == null then null else ipam.renderIPv6 identifier;

  protectedRuntimePrefix = context: tenant: routedPrefixesByTenant:
    let
      candidates = builtins.filter
        (prefix:
          builtins.isAttrs prefix
          && (prefix.family or null) == "ipv6"
          && (prefix.allocation or null) == "runtime"
          && isNonEmptyString (prefix.sourceFile or null)
          && lib.hasPrefix "/run/secrets/" prefix.sourceFile)
        (listOrEmpty (routedPrefixesByTenant.${tenant} or null));
    in
    requireOne context candidates;

in
{
  siteAttrs,
  services ? [ ],
  policyEndpointBindings ? { },
  interfaceRecords,
  routedPrefixesByTenant ? { },
  target,
  targetName,
}:
let
  communicationContract = attrsOrEmpty (siteAttrs.communicationContract or null);
  relations =
    if builtins.isList (communicationContract.relations or null) then
      communicationContract.relations
    else
      listOrEmpty (communicationContract.allowedRelations or null);
  publicIngressRelations = builtins.filter
    (relation:
      builtins.isAttrs relation
      && (relation.action or "allow") == "allow"
      && builtins.isAttrs (relation.publicIngressTupleAuthority or null)
      && (
        let
          authority = relation.publicIngressTupleAuthority;
          family = authority.family or null;
          mode = authority.translationMode or null;
        in
        (mode == "napt" && (family == null || family == "ipv4"))
        || (mode == "none" && family == "ipv6")
      ))
    relations;
  servicesByName = serviceIndex services;
  loopback4 = stripCidr ((attrsOrEmpty ((attrsOrEmpty target.effectiveRuntimeRealization).loopback or null)).addr4 or null);

  buildRecord = relation:
    let
      id = relationId relation;
      authority = attrsOrEmpty relation.publicIngressTupleAuthority;
      relationSurfaces = externalNames (relation.from or null);
      publicSurface = authority.publicSurface or null;
      surfaces = uniqueStrings (relationSurfaces ++ [ publicSurface ]);
      targetService = authority.targetService or ((attrsOrEmpty (relation.to or null)).name or null);
      service =
        if !isNonEmptyString targetService || !(builtins.hasAttr targetService servicesByName) then
          throw "public ingress relation '${toString id}' targets unresolved service '${toString targetService}'"
        else
          servicesByName.${targetService};
      targetEndpoint = authority.targetEndpoint or null;
      endpointCandidates = builtins.filter
        (endpoint:
          !isNonEmptyString targetEndpoint
          || ((attrsOrEmpty endpoint).name or null) == targetEndpoint)
        (listOrEmpty (service.providerEndpoints or null));
      endpoint = requireOne "relation '${toString id}' target endpoint" endpointCandidates;
      translationMode = authority.translationMode or null;
      family = if (authority.family or null) == "ipv6" then 6 else 4;
      targetAddress =
        if family == 6 then
          requireOne "relation '${toString id}' IPv6 target address" (endpointAddresses6 endpoint)
        else
          requireOne "relation '${toString id}' IPv4 target address" (endpointAddresses4 endpoint);
      targetAccessNode = requireOne
        "relation '${toString id}' target access node"
        (targetAccessNodesFor policyEndpointBindings service);

      pppoeIngress = builtins.filter
        (iface:
          iface.sourceKind == "pppoe-session"
          && builtins.elem ((attrsOrEmpty (iface.backingRef or null)).name or "") surfaces)
        interfaceRecords;
      wanIngress = builtins.filter
        (iface:
          iface.sourceKind == "wan"
          && (
            builtins.elem (iface.upstream or "") surfaces
            || builtins.elem iface.sourceInterfaceName surfaces
          ))
        interfaceRecords;
      ingressIface = requireOne
        "relation '${toString id}' runtime ingress interface"
        (if pppoeIngress != [ ] then pppoeIngress else wanIngress);

      internalEgressCandidates = builtins.filter
        (iface:
          let
            lane = attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);
          in
          iface.sourceKind == "p2p"
          && isNonEmptyString (iface.runtimeIfName or null)
          && (lane.kind or null) == "uplink"
          && builtins.elem (lane.uplink or "") surfaces)
        interfaceRecords;
      internalEgress = requireOne "relation '${toString id}' internal egress interface" internalEgressCandidates;
      internalNextHop =
        if family == 6 then p2pPeer6 (internalEgress.addr6 or null)
        else p2pPeer4 (internalEgress.addr4 or null);
      sourcePreservation = authority.sourcePreservation or null;
      returnBehavior = authority.returnBehavior or relation.returnBehavior or null;
      targetPort = authority.targetPort or null;
      tuples = listOrEmpty (authority.tuples or null);
      tupleRecords = map
        (tuple:
          let value = attrsOrEmpty tuple;
          in {
            protocol = value.protocol or null;
            publicPort = value.publicPort or null;
            inherit targetPort;
          })
        tuples;
      rewriteSource = sourcePreservation == "rewritten";
      destinationTranslation = translationMode != "none";
      providerTenant =
        if family == 6 then
          requireOne "relation '${toString id}' provider tenant" (listOrEmpty (service.providerTenants or null))
        else
          null;
      interfaceIdentifier = interfaceIdentifier64 targetAddress;
      runtimePrefix =
        if family != 6 then
          null
        else
          protectedRuntimePrefix
            "relation '${toString id}' protected runtime prefix"
            providerTenant
            routedPrefixesByTenant;
      runtimeDestination =
        if family != 6 then
          null
        else if !isNonEmptyString interfaceIdentifier then
          throw "public ingress relation '${toString id}' IPv6 endpoint has no stable interface identifier"
        else
          {
            sourceClass = "protected";
            source = "intent-routed-prefix";
            sourceFile = runtimePrefix.sourceFile;
            prefixName = runtimePrefix.name;
            inherit interfaceIdentifier;
            delegatedPrefixLength = runtimePrefix.delegatedPrefixLength;
            perTenantPrefixLength = runtimePrefix.perTenantPrefixLength;
            slot = runtimePrefix.slot;
            targetPrefixLength = 128;
          };
      complete =
        isNonEmptyString id
        && surfaces != [ ]
        && isNonEmptyString publicSurface
        && isNonEmptyString targetAddress
        && isNonEmptyString (ingressIface.runtimeIfName or null)
        && isNonEmptyString (internalEgress.runtimeIfName or null)
        && isNonEmptyString internalNextHop
        && builtins.isInt targetPort
        && tupleRecords != [ ]
        && builtins.all
          (tuple: isNonEmptyString tuple.protocol && builtins.isInt tuple.publicPort)
          tupleRecords
        && isNonEmptyString translationMode
        && isNonEmptyString sourcePreservation
        && isNonEmptyString returnBehavior
        && (!rewriteSource || (family == 4 && isNonEmptyString loopback4))
        && (family != 6 || (translationMode == "none" && sourcePreservation == "preserve-source"));
    in
    if !complete then
      throw "public ingress relation '${toString id}' has incomplete or ambiguous runtime realization"
    else
      {
        relationId = id;
        inherit family;
        sourceScope = authority.sourceScope or null;
        inherit publicSurface translationMode sourcePreservation returnBehavior;
        ingressInterface = ingressIface.runtimeIfName;
        publicAddressBinding = "runtime-interface-address";
        translationOwnerRuntimeTarget = targetName;
        target = {
          service = targetService;
          endpoint = targetEndpoint;
          address = targetAddress;
          port = targetPort;
          accessNode = targetAccessNode;
          providerTenants = listOrEmpty (service.providerTenants or null);
        };
        inherit tupleRecords destinationTranslation runtimeDestination;
        internalPath = {
          egressInterface = internalEgress.runtimeIfName;
          nextHop = internalNextHop;
          targetRoute = {
            dst = if family == 6 then null else "${targetAddress}/32";
            table = "main";
            inherit runtimeDestination;
          };
        };
        sourceTranslation =
          if rewriteSource then
            {
              mode = "snat";
              address = loopback4;
              owner = targetName;
            }
          else
            {
              mode = "none";
              address = null;
              owner = null;
            };
        consumers = [ "routing" "firewall" "renderer" "diagnostic" ];
      };
in
map buildRecord publicIngressRelations
