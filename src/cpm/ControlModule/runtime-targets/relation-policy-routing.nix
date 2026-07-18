{
  lib,
  common,
  ipam,
  sitePath,
  tenantPrefixOwners,
  allowedRelations,
  trafficPaths,
  serviceDefinitions,
  providerTenantsForServiceProvider,
  policyNodeName,
}:

let
  inherit (common) attrsOrEmpty failForwarding listOrEmpty;

  relationById = builtins.listToAttrs (
    builtins.map
      (relation: {
        name = relation.id;
        value = relation;
      })
      (
        builtins.filter (relation: builtins.isAttrs relation && builtins.isString (relation.id or null)) (
          listOrEmpty allowedRelations
        )
      )
  );

  targetLogicalName = target: (attrsOrEmpty (target.logicalNode or null)).name or null;
  interfacesFor =
    target:
    attrsOrEmpty ((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null);

  interfaceEntriesForLane =
    kind: access: target:
    builtins.filter
      (
        entry:
        let
          lane = attrsOrEmpty ((attrsOrEmpty (entry.value.backingRef or null)).lane or null);
        in
        (lane.kind or null) == kind && (lane.access or null) == access
      )
      (
        builtins.map (name: {
          inherit name;
          value = (interfacesFor target).${name};
        }) (builtins.attrNames (interfacesFor target))
      );

  requireSingleInterface =
    targetName: kind: access: target:
    let
      matches = interfaceEntriesForLane kind access target;
    in
    if builtins.length matches == 1 then
      builtins.head matches
    else
      failForwarding "${sitePath}.runtimeTargets.${targetName}.effectiveRuntimeRealization.interfaces" "FS-270-HDS-010-SDS-010-SMS-020: policy-required lateral path needs exactly one ${kind} interface for access '${access}'";

  prefixRecordsFor =
    family: tenant: owner:
    builtins.filter (
      record:
      builtins.isAttrs record
      && (record.family or null) == family
      && (record.netName or null) == tenant
      && (record.owner or null) == owner
      && builtins.isString (record.dst or null)
    ) (builtins.attrValues (attrsOrEmpty tenantPrefixOwners));

  serviceProviderTenants =
    serviceName:
    let
      service = attrsOrEmpty (serviceDefinitions.${serviceName} or null);
    in
    lib.unique (
      lib.concatMap providerTenantsForServiceProvider (listOrEmpty (service.providers or null))
    );

  relationSupportsFamily =
    family: relation:
    let
      familyName = if family == 4 then "ipv4" else "ipv6";
    in
    builtins.any (
      match:
      builtins.elem (match.family or "any") [
        "any"
        familyName
      ]
    ) (listOrEmpty (relation.match or null));

  pathCandidate =
    path:
    let
      relationId = path.relationId or null;
      relation =
        if builtins.isString relationId then attrsOrEmpty (relationById.${relationId} or null) else { };
      from = attrsOrEmpty (relation.from or null);
      to = attrsOrEmpty (relation.to or null);
      nodePath = listOrEmpty (path.nodePath or null);
      stagePath = listOrEmpty (path.stagePath or null);
    in
    relation != { }
    && (relation.action or null) == "allow"
    && builtins.elem (relation.returnBehavior or null) [
      "symmetric"
      "stateful-return"
    ]
    && (from.kind or null) == "tenant"
    && builtins.isString (from.name or null)
    && (to.kind or null) == "service"
    && builtins.isString (to.name or null)
    && (path.requiresPolicy or false)
    && builtins.length nodePath == 5
    &&
      stagePath == [
        "access"
        "downstream-selector"
        "policy"
        "downstream-selector"
        "access"
      ]
    && builtins.elemAt nodePath 1 == builtins.elemAt nodePath 3
    && builtins.elemAt nodePath 2 == policyNodeName
    && builtins.elemAt nodePath 0 != builtins.elemAt nodePath 4;

  candidates = builtins.sort (
    left: right:
    let
      leftRelation = relationById.${left.relationId};
      rightRelation = relationById.${right.relationId};
      leftPriority = leftRelation.priority or 2147483647;
      rightPriority = rightRelation.priority or 2147483647;
    in
    if leftPriority == rightPriority then
      left.relationId < right.relationId
    else
      leftPriority < rightPriority
  ) (builtins.filter pathCandidate (listOrEmpty trafficPaths));

  p2pPeerAddress =
    family: cidr:
    let
      parsed = if builtins.isString cidr then ipam.splitCIDR cidr else null;
      expectedPrefixLen = if family == 4 then 31 else 127;
      parsedAddress =
        if parsed == null || parsed.prefixLen != expectedPrefixLen then
          null
        else if family == 4 then
          ipam.parseIPv4 parsed.addr
        else
          ipam.parseIPv6 parsed.addr;
      ipv4PeerInt =
        if parsedAddress == null || family != 4 then
          null
        else
          let
            addrInt = ipam.ipv4ToInt parsedAddress;
          in
          if lib.mod addrInt 2 == 0 then addrInt + 1 else addrInt - 1;
      ipv6Peer =
        if parsedAddress == null || family != 6 then
          null
        else
          builtins.genList (
            index:
            if index == 7 then
              if lib.mod (builtins.elemAt parsedAddress 7) 2 == 0 then
                (builtins.elemAt parsedAddress 7) + 1
              else
                (builtins.elemAt parsedAddress 7) - 1
            else
              builtins.elemAt parsedAddress index
          ) 8;
    in
    if parsedAddress == null then
      null
    else if family == 4 then
      ipam.renderIPv4 (ipam.ipv4FromInt ipv4PeerInt)
    else
      ipam.renderIPv6 ipv6Peer;

  minimumGenericPriority =
    target:
    let
      priorities = builtins.sort builtins.lessThan (
        builtins.map (
          iface: (attrsOrEmpty (iface.policyRoutingAllocation or null)).tableRulePriority or 2147483647
        ) (builtins.attrValues (interfacesFor target))
      );
    in
    if priorities == [ ] then 2147483647 else builtins.head priorities;

  prefixPairsFor =
    family: relation: sourceAccess: destinationAccess:
    let
      from = attrsOrEmpty relation.from;
      to = attrsOrEmpty relation.to;
      destinationTenants = serviceProviderTenants to.name;
      sourcePrefixes = prefixRecordsFor family from.name sourceAccess;
      destinationPrefixes = lib.concatMap (
        tenant: prefixRecordsFor family tenant destinationAccess
      ) destinationTenants;
    in
    if !relationSupportsFamily family relation then
      [ ]
    else
      lib.concatMap (
        sourceRecord:
        builtins.map (destinationRecord: {
          sourcePrefix = sourceRecord.dst;
          destinationPrefix = destinationRecord.dst;
        }) destinationPrefixes
      ) sourcePrefixes;

  realizationForCandidate =
    targetName: target: priority: path:
    let
      relation = relationById.${path.relationId};
      nodePath = path.nodePath;
      sourceAccess = builtins.elemAt nodePath 0;
      destinationAccess = builtins.elemAt nodePath 4;
      sourceEdge = requireSingleInterface targetName "access-edge" sourceAccess target;
      destinationEdge = requireSingleInterface targetName "access-edge" destinationAccess target;
      sourcePolicy = requireSingleInterface targetName "access" sourceAccess target;
      destinationPolicy = requireSingleInterface targetName "access" destinationAccess target;
      pairsByFamily =
        lib.concatMap
          (
            family:
            builtins.map (pair: pair // { inherit family; }) (
              prefixPairsFor family relation sourceAccess destinationAccess
            )
          )
          [
            4
            6
          ];
      _hasAddressAuthority =
        if pairsByFamily != [ ] then
          true
        else
          failForwarding "${sitePath}.trafficPaths.${path.relationId}" "FS-270-HDS-010-SDS-010-SMS-020: policy-required lateral service has no shared source and provider address-family authority";
      selectorFor =
        direction: pair:
        let
          forward = direction == "forward";
          incoming = if forward then sourceEdge.value else destinationEdge.value;
          policy = if forward then sourcePolicy.value else destinationPolicy.value;
          sourcePrefix = if forward then pair.sourcePrefix else pair.destinationPrefix;
          destinationPrefix = if forward then pair.destinationPrefix else pair.sourcePrefix;
        in
        {
          authority = "relation-policy-state-owner";
          relationId = path.relationId;
          relationPriority = relation.priority or null;
          inherit
            direction
            sourcePrefix
            destinationPrefix
            priority
            ;
          family = pair.family;
          incomingInterface = incoming.runtimeIfName;
          policyInterface = policy.runtimeIfName;
          tableId = policy.policyRoutingAllocation.tableId;
          policyStateOwner = policyNodeName;
          returnBehavior = relation.returnBehavior;
          trafficType = relation.trafficType;
          service = relation.to.name;
          path = nodePath;
        };
      selectors = builtins.seq _hasAddressAuthority (
        lib.concatMap (pair: [
          (selectorFor "forward" pair)
          (selectorFor "return" pair)
        ]) pairsByFamily
      );
      routeEntryFor =
        selector:
        let
          forward = selector.direction == "forward";
          policyEntry = if forward then sourcePolicy else destinationPolicy;
          addressField = if selector.family == 4 then "addr4" else "addr6";
          viaField = if selector.family == 4 then "via4" else "via6";
          peer = p2pPeerAddress selector.family (policyEntry.value.${addressField} or null);
          _hasPeer =
            if peer != null then
              true
            else
              failForwarding "${sitePath}.runtimeTargets.${targetName}.effectiveRuntimeRealization.interfaces.${policyEntry.name}.${addressField}" "FS-270-HDS-010-SDS-010-SMS-020: selected policy-state lane requires a point-to-point peer";
        in
        builtins.seq _hasPeer {
          interfaceName = policyEntry.name;
          family = selector.family;
          route = {
            dst = selector.destinationPrefix;
            proto = "internal";
            policyOnly = true;
            lane = (attrsOrEmpty policyEntry.value.backingRef).lane or { };
            reason = "relation-policy-state-owner";
            relationId = selector.relationId;
            relationIds = [ selector.relationId ];
            returnBehavior = selector.returnBehavior;
            trafficType = selector.trafficType;
            ${viaField} = peer;
            intent = {
              kind = "relation-policy-reachability";
              source = "trafficPaths";
              relationId = selector.relationId;
              direction = selector.direction;
              policyStateOwner = selector.policyStateOwner;
            };
          };
        };
    in
    {
      inherit selectors;
      routeEntries = builtins.map routeEntryFor selectors;
    };

  addForTarget =
    targetName: target:
    let
      logicalName = targetLogicalName target;
      targetCandidates = builtins.filter (
        path: builtins.elemAt path.nodePath 1 == logicalName
      ) candidates;
      count = builtins.length targetCandidates;
      genericPriority = minimumGenericPriority target;
      priorityBase = genericPriority - count;
      _priorityCapacity =
        if count == 0 || priorityBase > 0 then
          true
        else
          failForwarding "${sitePath}.runtimeTargets.${targetName}.effectiveRuntimeRealization.routeSelectionRules" "FS-270-HDS-010-SDS-010-SMS-020: relation route-selection priority space is exhausted";
      realizations = builtins.seq _priorityCapacity (
        builtins.genList (
          index:
          realizationForCandidate targetName target (priorityBase + index) (
            builtins.elemAt targetCandidates index
          )
        ) count
      );
      selectors = lib.concatMap (realization: realization.selectors) realizations;
      routeEntries = lib.concatMap (realization: realization.routeEntries) realizations;
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = interfacesFor target;
      updatedInterfaces = builtins.mapAttrs (
        interfaceName: iface:
        let
          additionsFor =
            family:
            builtins.map (entry: entry.route) (
              builtins.filter (entry: entry.interfaceName == interfaceName && entry.family == family) routeEntries
            );
          routes = attrsOrEmpty (iface.routes or null);
        in
        iface
        // {
          routes = routes // {
            ipv4 = listOrEmpty (routes.ipv4 or null) ++ additionsFor 4;
            ipv6 = listOrEmpty (routes.ipv6 or null) ++ additionsFor 6;
          };
        }
      ) interfaces;
    in
    if count == 0 then
      target
    else
      target
      // {
        effectiveRuntimeRealization = effective // {
          interfaces = updatedInterfaces;
          routeSelectionRules = listOrEmpty (effective.routeSelectionRules or null) ++ selectors;
        };
      };
in
runtimeTargets: builtins.mapAttrs addForTarget runtimeTargets
