{ lib, common }:

let
  inherit (common) attrsOrEmpty listOrEmpty ipam;
  isNonEmptyString = value: builtins.isString value && value != "";

  laneFor = iface: attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);
  backingRefFor = iface: attrsOrEmpty (iface.backingRef or null);

  p2pPeer4 =
    cidr:
    let
      parts = if builtins.isString cidr then lib.splitString "/" cidr else [ ];
      octets = if builtins.length parts == 2 then lib.splitString "." (builtins.head parts) else [ ];
      valid =
        builtins.length parts == 2 && builtins.elemAt parts 1 == "31" && builtins.length octets == 4;
      numbers = if valid then map lib.toInt octets else [ ];
      last = if valid then builtins.elemAt numbers 3 else 0;
      peerLast = if lib.mod last 2 == 0 then last + 1 else last - 1;
    in
    if !valid then
      null
    else
      builtins.concatStringsSep "." (
        builtins.genList (
          index: builtins.toString (if index == 3 then peerLast else builtins.elemAt numbers index)
        ) 4
      );

  p2pPeer6 =
    cidr:
    let
      parsed = if builtins.isString cidr then ipam.splitCIDR cidr else null;
      address = if parsed != null && parsed.prefixLen == 127 then ipam.parseIPv6 parsed.addr else null;
      peer =
        if address == null then
          null
        else
          builtins.genList (
            index:
            if index != 7 then
              builtins.elemAt address index
            else if lib.mod (builtins.elemAt address index) 2 == 0 then
              (builtins.elemAt address index) + 1
            else
              (builtins.elemAt address index) - 1
          ) 8;
    in
    if peer == null then null else ipam.renderIPv6 peer;

  routeFor =
    {
      relationId,
      kind,
      dst,
      iface,
    }:
    let
      via4 = if iface.sourceKind == "tenant" then null else p2pPeer4 (iface.addr4 or null);
      base = {
        inherit dst relationId;
        proto = "internal";
        intent = {
          inherit kind;
          source = "public-ingress-tuple-authority";
        };
      };
    in
    if via4 == null then base else base // { inherit via4; };

  routeAlreadyPresent =
    route: existing:
    (existing.dst or null) == (route.dst or null) && (existing.via4 or null) == (route.via4 or null);

  appendRoute =
    iface: route:
    let
      routes = attrsOrEmpty (iface.routes or null);
      ipv4 = listOrEmpty (routes.ipv4 or null);
    in
    if builtins.any (routeAlreadyPresent route) ipv4 then
      iface
    else
      iface
      // {
        routes = routes // {
          ipv4 = ipv4 ++ [ route ];
        };
      };

  matchingInterfaces =
    predicate: interfaces: builtins.filter predicate (builtins.attrValues interfaces);

  requireAtMostOne =
    context: values:
    if builtins.length values <= 1 then
      values
    else
      throw "public ingress ${context} is ambiguous; resolved ${builtins.toString (builtins.length values)} runtime interfaces";

  interfaceNameFor =
    interfaces: iface:
    builtins.head (
      builtins.filter (
        name: (interfaces.${name}.runtimeIfName or null) == (iface.runtimeIfName or null)
      ) (builtins.attrNames interfaces)
    );

  targetEgressCandidates =
    targetName: target: record:
    let
      role = target.role or null;
      logicalNode = (attrsOrEmpty (target.logicalNode or null)).name or null;
      targetAccess = (attrsOrEmpty (record.target or null)).accessNode or null;
      providerTenants = listOrEmpty ((attrsOrEmpty (record.target or null)).providerTenants or null);
      publicSurface = record.publicSurface or null;
      interfaces = attrsOrEmpty (
        (attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null
      );
    in
    matchingInterfaces (
      iface:
      let
        lane = laneFor iface;
      in
      if role == "core" then
        targetName == (record.translationOwnerRuntimeTarget or null)
        &&
          (iface.runtimeIfName or null)
          == ((attrsOrEmpty (record.internalPath or null)).egressInterface or null)
      else if role == "upstream-selector" then
        (lane.kind or null) == "access-uplink"
        && (lane.access or null) == targetAccess
        && (lane.uplink or null) == publicSurface
      else if role == "policy" then
        (lane.kind or null) == "access" && (lane.access or null) == targetAccess
      else if role == "downstream-selector" then
        (lane.kind or null) == "access-edge" && (lane.access or null) == targetAccess
      else if role == "access" && logicalNode == targetAccess then
        iface.sourceKind == "tenant" && builtins.elem ((backingRefFor iface).name or "") providerTenants
      else
        false
    ) interfaces;

  returnEgressCandidates =
    target: record:
    let
      role = target.role or null;
      logicalNode = (attrsOrEmpty (target.logicalNode or null)).name or null;
      targetAccess = (attrsOrEmpty (record.target or null)).accessNode or null;
      publicSurface = record.publicSurface or null;
      interfaces = attrsOrEmpty (
        (attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null
      );
    in
    matchingInterfaces (
      iface:
      let
        lane = laneFor iface;
      in
      if role == "upstream-selector" then
        (lane.kind or null) == "uplink" && (lane.uplink or null) == publicSurface
      else if role == "policy" then
        (lane.kind or null) == "access-uplink"
        && (lane.access or null) == targetAccess
        && (lane.uplink or null) == publicSurface
      else if role == "downstream-selector" then
        (lane.kind or null) == "access" && (lane.access or null) == targetAccess
      else if role == "access" && logicalNode == targetAccess then
        (lane.kind or null) == "access-edge" && (lane.access or null) == targetAccess
      else
        false
    ) interfaces;

  publicIngressRecords =
    runtimeTargets:
    builtins.concatMap (
      targetName:
      map (record: record // { _translationOwner = targetName; }) (
        listOrEmpty ((attrsOrEmpty (runtimeTargets.${targetName}.natIntent or null)).publicIngress or null)
      )
    ) (builtins.attrNames runtimeTargets);

  augmentForRecord =
    targetName: target: record:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      forwardingIntent = attrsOrEmpty (target.forwardingIntent or null);
      forwardingRules = listOrEmpty (forwardingIntent.rules or null);
      targetCandidates =
        requireAtMostOne "relation '${record.relationId}' target path on '${targetName}'"
          (targetEgressCandidates targetName target record);
      returnCandidates = requireAtMostOne "relation '${record.relationId}' return path on '${targetName}'" (
        returnEgressCandidates target record
      );
      targetAddress = (attrsOrEmpty (record.target or null)).address or null;
      targetPort = (attrsOrEmpty (record.target or null)).port or null;
      family = record.family or 4;
      runtimeDestination = attrsOrEmpty (record.runtimeDestination or null);
      hasRuntimeDestination =
        family == 6
        && isNonEmptyString (runtimeDestination.sourceFile or null)
        && isNonEmptyString (runtimeDestination.interfaceIdentifier or null);
      rewriteAddress = (attrsOrEmpty (record.sourceTranslation or null)).address or null;
      role = target.role or null;
      coreFromInterface = record.ingressInterface or null;
      coreToInterface = (attrsOrEmpty (record.internalPath or null)).egressInterface or null;
      relationId = record.relationId;
      returnBehavior = record.returnBehavior;
      policyStateOwner = (attrsOrEmpty (target.logicalNode or null)).name or "policy";
      exactForwardRule =
        if
          (!hasRuntimeDestination && !isNonEmptyString targetAddress)
          || !builtins.isInt targetPort
          || (role == "core" && !hasRuntimeDestination)
          || (role == "core" && !(isNonEmptyString coreFromInterface && isNonEmptyString coreToInterface))
          || (role != "core" && (targetCandidates == [ ] || returnCandidates == [ ]))
        then
          null
        else
          let
            fromInterface =
              if role == "core" then coreFromInterface else (builtins.head returnCandidates).runtimeIfName;
            toInterface =
              if role == "core" then coreToInterface else (builtins.head targetCandidates).runtimeIfName;
          in
          {
            action = "accept";
            inherit fromInterface toInterface;
            relationId = record.relationId;
            trafficType = "public-ingress";
            inherit (record)
              returnBehavior
              translationMode
              sourcePreservation
              destinationTranslation
              ;
            matches = map (tuple: {
              family = if family == 6 then "ipv6" else "ipv4";
              proto = tuple.protocol;
              dports = [ targetPort ];
            }) (listOrEmpty (record.tupleRecords or null));
            destinationPrefixes =
              if hasRuntimeDestination then
                [ ]
              else
                [
                  {
                    inherit family;
                    prefix = "${targetAddress}/${if family == 6 then "128" else "32"}";
                  }
                ];
            destinationRuntimeAddresses = if hasRuntimeDestination then [ runtimeDestination ] else [ ];
            transportAuthority = {
              admissible = true;
              basis = "public-ingress-tuple-authority";
              provenanceIsAuthority = false;
            };
            intent = {
              kind =
                if (record.destinationTranslation or false) then
                  "public-ingress-post-dnat-forward"
                else
                  "public-ingress-runtime-destination-forward";
              source = "public-ingress-tuple-authority";
            };
            comment = "${record.relationId}: exact public ingress";
          };
      # FS-220 / FS-230: each public-ingress tuple (protocol + port) is an
      # independently authorized path. Two tuples on the same relation and
      # runtime path therefore produce distinct forwarding rules, so the
      # replace-dedup key must include the rule's matches (protocol + port).
      # A generic rule on the same path (no tuple matches) is a placeholder
      # the exact tuple rule refines and is always replaced; a previously
      # emitted exact tuple rule is replaced only when it is the same tuple.
      sameExactPath =
        rule:
        exactForwardRule != null
        && builtins.isAttrs rule
        && (rule.relationId or null) == record.relationId
        && (rule.fromInterface or null) == exactForwardRule.fromInterface
        && (rule.toInterface or null) == exactForwardRule.toInterface
        && (
          (rule.matches or null) == null
          || (rule.matches or null) == exactForwardRule.matches
        );
      withForwarding =
        if exactForwardRule == null then
          target
        else
          target
          // {
            forwardingIntent = forwardingIntent // {
              rules = (builtins.filter (rule: !(sameExactPath rule)) forwardingRules) ++ [ exactForwardRule ];
            };
          };
      withTarget =
        if hasRuntimeDestination && (role == "core" || targetCandidates != [ ]) then
          let
            candidates =
              if role == "core" then
                builtins.filter (iface: (iface.runtimeIfName or null) == coreToInterface) (
                  builtins.attrValues interfaces
                )
              else
                targetCandidates;
            candidate =
              if builtins.length candidates == 1 then
                builtins.head candidates
              else
                throw "public ingress relation '${record.relationId}' runtime IPv6 path on '${targetName}' is missing or ambiguous";
            routes = attrsOrEmpty (candidate.routes or null);
            hasProtectedRoute = builtins.any (
              route: (route.sourceFile or null) == runtimeDestination.sourceFile
            ) (listOrEmpty (routes.ipv6 or null));
            via6 =
              if (candidate.sourceKind or null) == "tenant" then null else p2pPeer6 (candidate.addr6 or null);
            providerTenants = listOrEmpty ((attrsOrEmpty (record.target or null)).providerTenants or null);
            providerTenant =
              if builtins.length providerTenants == 1 then
                builtins.head providerTenants
              else
                throw "public ingress relation '${record.relationId}' provider tenant is missing or ambiguous";
            protectedRoute = {
              family = 6;
              sourceFile = runtimeDestination.sourceFile;
              prefixName = runtimeDestination.prefixName or null;
              delegatedPrefixLength = runtimeDestination.delegatedPrefixLength;
              perTenantPrefixLength = runtimeDestination.perTenantPrefixLength;
              slot = runtimeDestination.slot;
              tenant = providerTenant;
              proto = "internal";
              intent = {
                kind = "runtime-routed-prefix-return";
                source = "public-ingress-runtime-destination";
                accessNode = (attrsOrEmpty (record.target or null)).accessNode or null;
              };
            }
            // (if via6 == null then { } else { inherit via6; });
            candidateWithRoute = candidate // {
              routes = routes // {
                ipv6 = listOrEmpty (routes.ipv6 or null) ++ [ protectedRoute ];
              };
            };
            candidateName = interfaceNameFor interfaces candidate;
          in
          if (candidate.sourceKind or null) != "tenant" && via6 == null then
            throw "public ingress relation '${record.relationId}' runtime IPv6 route on '${targetName}' has no exact next hop"
          else if hasProtectedRoute then
            interfaces
          else
            interfaces // { ${candidateName} = candidateWithRoute; }
        else if hasRuntimeDestination then
          interfaces
        else if targetCandidates == [ ] || !isNonEmptyString targetAddress then
          interfaces
        else
          let
            iface = builtins.head targetCandidates;
            name = interfaceNameFor interfaces iface;
            route = routeFor {
              relationId = record.relationId;
              kind = "public-ingress-target-reachability";
              dst = "${targetAddress}/32";
              inherit iface;
            };
          in
          interfaces // { ${name} = appendRoute iface route; };
      withReturn =
        if returnCandidates == [ ] || !isNonEmptyString rewriteAddress then
          withTarget
        else
          let
            candidate = builtins.head returnCandidates;
            name = interfaceNameFor interfaces candidate;
            iface = withTarget.${name};
            route = routeFor {
              inherit relationId;
              kind = "public-ingress-source-return";
              dst = "${rewriteAddress}/32";
              inherit iface;
            };
          in
          withTarget // { ${name} = appendRoute iface route; };

      # FS-230 / FS-310: public ingress is a relation-bound stateful path, but
      # its post-SNAT source (the core loopback rewrite address) is also an
      # "internal-reachability" return prefix that the runtime-origin route
      # machinery copies into every tenant policy table. The policy then
      # resolves the DNAT forward source over a wrong tenant lane and drops
      # the packet. Emit explicit relation-bound forward/return selectors and
      # policy-only reachability routes so the policy routes the ingress on
      # the modeled access-uplink lane instead of the shared return prefix.
      relationPolicyRouteFor =
        iface: direction: dst:
        let
          via4 = p2pPeer4 (iface.addr4 or null);
          base = {
            inherit dst relationId;
            proto = "internal";
            policyOnly = true;
            intent = {
              kind = "relation-policy-reachability";
              source = "public-ingress-tuple-authority";
              relationId = record.relationId;
              inherit direction policyStateOwner;
            };
          };
        in
        if via4 == null then base else base // { inherit via4; };

      withSelectors =
        let
          existingRules = listOrEmpty (effective.routeSelectionRules or null);
          selectorPresent =
            direction:
            builtins.any
              (
                rule:
                (rule.relationId or null) == relationId
                && (rule.direction or null) == direction
                && (rule.family or null) == family
              )
              existingRules;
        in
        if
          role != "policy"
          || family != 4
          || targetCandidates == [ ]
          || returnCandidates == [ ]
          || !isNonEmptyString rewriteAddress
          || !isNonEmptyString targetAddress
          || (selectorPresent "forward" && selectorPresent "return")
        then
          effective // { interfaces = withReturn; }
        else
          let
            targetCandidate = builtins.head targetCandidates;
            returnCandidate = builtins.head returnCandidates;
            targetCandidateName = interfaceNameFor interfaces targetCandidate;
            returnCandidateName = interfaceNameFor interfaces returnCandidate;
            targetCandidateTable = (attrsOrEmpty (targetCandidate.policyRoutingAllocation or null)).tableId or null;
            returnCandidateTable = (attrsOrEmpty (returnCandidate.policyRoutingAllocation or null)).tableId or null;
            service = (attrsOrEmpty (record.target or null)).service or null;
            selectorPriority = 900;
            selectorFor =
              direction: incomingCandidate: policyCandidate: sourcePrefix: destinationPrefix: tableId:
              {
                authority = "relation-policy-state-owner";
                inherit relationId direction family returnBehavior policyStateOwner service tableId sourcePrefix destinationPrefix;
                trafficType = "public-ingress";
                priority = selectorPriority;
                incomingInterface = incomingCandidate.runtimeIfName;
                policyInterface = policyCandidate.runtimeIfName;
              };
            forwardSelector =
              selectorFor "forward" returnCandidate targetCandidate "${rewriteAddress}/32" "${targetAddress}/32" targetCandidateTable;
            returnSelector =
              selectorFor "return" targetCandidate returnCandidate "${targetAddress}/32" "${rewriteAddress}/32" returnCandidateTable;
            forwardRoute = relationPolicyRouteFor targetCandidate "forward" "${targetAddress}/32";
            returnRoute = relationPolicyRouteFor returnCandidate "return" "${rewriteAddress}/32";
            targetCandidateWithRoute = targetCandidate // {
              routes = (attrsOrEmpty (targetCandidate.routes or null)) // {
                ipv4 = listOrEmpty ((attrsOrEmpty (targetCandidate.routes or null)).ipv4 or null) ++ [ forwardRoute ];
              };
            };
            returnCandidateWithRoute = returnCandidate // {
              routes = (attrsOrEmpty (returnCandidate.routes or null)) // {
                ipv4 = listOrEmpty ((attrsOrEmpty (returnCandidate.routes or null)).ipv4 or null) ++ [ returnRoute ];
              };
            };
          in
          effective
          // {
            interfaces = withReturn // {
              ${targetCandidateName} = targetCandidateWithRoute;
              ${returnCandidateName} = returnCandidateWithRoute;
            };
            routeSelectionRules =
              listOrEmpty (effective.routeSelectionRules or null) ++ [
                forwardSelector
                returnSelector
              ];
          };
    in
    if withSelectors == effective then
      withForwarding
    else
      withForwarding
      // {
        effectiveRuntimeRealization = withSelectors;
      };

in
runtimeTargets:
let
  records = publicIngressRecords runtimeTargets;
in
builtins.foldl' (
  targets: record:
  builtins.mapAttrs (targetName: target: augmentForRecord targetName target record) targets
) runtimeTargets records
