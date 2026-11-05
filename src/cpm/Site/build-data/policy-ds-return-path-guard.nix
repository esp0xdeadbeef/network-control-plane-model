{ lib
, common
,
}:

{ tenantPrefixOwners ? { }
, runtimeTargets ? { }
,
}:

let
  inherit (common) attrsOrEmpty listOrEmpty;

  isNonEmptyString = value:
    builtins.isString value && value != "";

  defaultDst = family:
    if family == 4 then "0.0.0.0/0" else "::/0";

  routeIntent = route:
    attrsOrEmpty (route.intent or null);

  routeLane = route:
    attrsOrEmpty (route.lane or null);

  interfaceLane = iface:
    attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);

  familyRoutes =
    family: iface:
    listOrEmpty ((attrsOrEmpty (iface.routes or null))."ipv${builtins.toString family}" or null);

  ownerEntries =
    builtins.filter
      (owner:
        (owner.family or null) != null
        && isNonEmptyString (owner.dst or null)
        && isNonEmptyString (owner.owner or null))
      (builtins.attrValues tenantPrefixOwners);

  ownerIndex =
    builtins.listToAttrs (
      builtins.map
        (owner: {
          name = "${builtins.toString owner.family}|${owner.dst}";
          value = owner;
        })
        ownerEntries
    );

  ownerFor =
    family: dst:
    if isNonEmptyString dst then ownerIndex."${builtins.toString family}|${dst}" or null else null;

  ownerPrefixesForAccess =
    access:
    builtins.filter (owner: owner.owner == access) ownerEntries;

  isReturnPathRoute =
    family: route:
    let
      intent = routeIntent route;
    in
    (route.policyOnly or false) == true
    && (route.reason or null) == "policy-table-internal-reachability"
    && (intent.source or null) == "policy-default-lane"
    && (intent.kind or null) == "internal-reachability"
    && ownerFor family (route.dst or null) != null;

  isPolicyDefaultRoute =
    family: route:
    (route.policyOnly or false) == true
    && (route.direction or null) == "outbound"
    && (route.dst or null) == defaultDst family;

  hasPolicyDefaultRoute =
    iface:
    builtins.any (isPolicyDefaultRoute 4) (familyRoutes 4 iface)
    || builtins.any (isPolicyDefaultRoute 6) (familyRoutes 6 iface);

  egressAccessEntriesForTarget =
    targetName:
    let
      target = attrsOrEmpty (runtimeTargets.${targetName} or null);
      interfaces = attrsOrEmpty ((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null);
    in
    if (target.role or "") != "policy" then
      [ ]
    else
      builtins.concatMap
        (ifName:
          let
            iface = attrsOrEmpty (interfaces.${ifName} or null);
            lane = interfaceLane iface;
          in
          if
            (lane.kind or null) == "access-uplink"
            && isNonEmptyString (lane.access or null)
            && hasPolicyDefaultRoute iface
          then
            [{ name = lane.access; value = true; }]
          else
            [ ])
        (builtins.attrNames interfaces);

  egressAccessSet =
    builtins.listToAttrs (
      builtins.concatMap egressAccessEntriesForTarget (builtins.attrNames runtimeTargets)
    );

  hasEgressAccess = access:
    egressAccessSet.${access} or false;

  isCandidateInterface =
    role: iface:
    let
      lane = interfaceLane iface;
      kind = lane.kind or null;
    in
    (iface.sourceKind or null) == "p2p"
    && isNonEmptyString (lane.access or null)
    && hasEgressAccess lane.access
    && (
      (role == "policy" && kind == "access")
      || (role == "downstream-selector" && kind == "access-edge")
    );

  wrongLaneDiagnosticsFor =
    targetName: role: ifName: iface: family:
    let
      ifaceLane = interfaceLane iface;
      ifaceAccess = ifaceLane.access or null;
      routes = builtins.filter (isReturnPathRoute family) (familyRoutes family iface);
    in
    builtins.concatMap
      (route:
        let
          owner = ownerFor family (route.dst or null);
          expectedAccess = owner.owner or null;
          actualAccess = (routeLane route).access or ifaceAccess;
        in
        if expectedAccess == ifaceAccess && expectedAccess == actualAccess then
          [ ]
        else if expectedAccess != ifaceAccess then
          # FS-370-HDS-010-SDS-010-SMS-101: the returned prefix's owning lane
          # must be the lane of the interface carrying this return route. When
          # they disagree the route sends return traffic back through an
          # interface that does not serve the destination prefix's lane, which
          # is exactly the defect this guard exists to reject. Reporting it is
          # required rather than skipping it, otherwise a wrong-lane return
          # path fails open.
          [
            {
              code = "policy-ds-return-path-wrong-lane";
              inherit family;
              runtimeTarget = targetName;
              interface = ifName;
              role = role;
              prefix = route.dst or null;
              expectedLane = expectedAccess;
              actualLane = actualAccess;
              interfaceLane = ifaceAccess;
            }
          ]
        else
          [
            {
              code = "policy-ds-return-path-wrong-lane";
              inherit family;
              runtimeTarget = targetName;
              interface = ifName;
              role = role;
              prefix = route.dst or null;
              expectedLane = expectedAccess;
              actualLane = actualAccess;
              interfaceLane = ifaceAccess;
            }
          ])
      routes;

  hasReturnPathRoute =
    family: access: prefix: iface:
    builtins.any
      (route:
        isReturnPathRoute family route
        && (route.dst or null) == prefix
        && ((routeLane route).access or null) == access)
      (familyRoutes family iface);

  # Lanes of a target that carry a policy default for a given address family.
  # The default is normally on the lane's uplink-facing interface, so the lane
  # is identified from every interface of the target, not from one interface.
  laneOwnersWithDefault =
    family: target:
    let
      interfaces = attrsOrEmpty ((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null);
      laneOf =
        iface:
        let
          lane = interfaceLane iface;
        in
        if (lane.access or null) == null then null else lane.access;
      lanesWithDefault = builtins.concatMap
        (ifName:
          let
            iface = attrsOrEmpty (interfaces.${ifName} or null);
            lane = laneOf iface;
          in
          if lane != null && builtins.any (route: (route.dst or null) == defaultDst family) (familyRoutes family iface)
          then [ lane ]
          else [ ])
        (builtins.attrNames interfaces);
    in
    builtins.attrNames (builtins.listToAttrs (map (lane: { name = lane; value = true; }) lanesWithDefault));

  missingDiagnosticsFor =
    targetName: role: ifName: iface:
    target:
    let
      access = (interfaceLane iface).access or null;
      ownerPrefixes = ownerPrefixesForAccess access;
      # FS-370: a lane needs a per-lane return path for a prefix only when that
      # lane actually reaches an exit for the prefix's address family. On a
      # policy node the exit default sits on the uplink-facing interface of the
      # lane while the return routes belong on the access-facing interface, so
      # the requirement is decided per LANE across the whole target, not from
      # the defaults present on this single interface. A lane with no policy
      # default for a family (for example an example that models no IPv6 exit)
      # has no return traffic to derive and is not required to carry that
      # family. The previous gate keyed on surviving return routes instead,
      # which made the check vacuous once every return route was stripped.
      laneHasPolicyDefault =
        family:
        let
          owners = laneOwnersWithDefault family target;
        in
        access != null && builtins.elem access owners;
      missingFor =
        family:
        if !(laneHasPolicyDefault family) then
          [ ]
        else
          builtins.concatMap
            (owner:
              let
                prefix = owner.dst;
              in
              if owner.family != family then
                [ ]
              else if hasReturnPathRoute family access prefix iface then
                [ ]
              else
                [
                  {
                    code = "policy-ds-return-path-missing";
                    inherit family prefix;
                    runtimeTarget = targetName;
                    interface = ifName;
                    role = role;
                    expectedLane = access;
                  }
                ])
            ownerPrefixes;
    in
    missingFor 4 ++ missingFor 6;

  diagnosticsForInterface =
    targetName: target: ifName:
    let
      role = target.role or "";
      iface = attrsOrEmpty (((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or { }).${ifName} or null);
    in
    if !(isCandidateInterface role iface) then
      [ ]
    else
      (wrongLaneDiagnosticsFor targetName role ifName iface 4)
      ++ (wrongLaneDiagnosticsFor targetName role ifName iface 6)
      ++ (missingDiagnosticsFor targetName role ifName iface target);

  diagnosticsForTarget =
    targetName:
    let
      target = attrsOrEmpty (runtimeTargets.${targetName} or null);
      interfaces = attrsOrEmpty ((attrsOrEmpty (target.effectiveRuntimeRealization or null)).interfaces or null);
    in
    builtins.concatMap
      (ifName: diagnosticsForInterface targetName target ifName)
      (builtins.attrNames interfaces);

  diagnostics =
    builtins.concatMap diagnosticsForTarget (builtins.attrNames runtimeTargets);

in
if diagnostics == [ ] then
  true
else
  throw "FS-370-HDS-010-SDS-010-SMS-101: policy/DS per-lane return-path validation failed: ${builtins.toJSON diagnostics}"
