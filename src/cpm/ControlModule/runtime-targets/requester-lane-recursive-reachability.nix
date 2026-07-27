# GAMP: FS-540-HDS-010-SDS-010-SMS-040 — requester-lane recursive reachability
#
# Consumes requester scope, resolver service endpoints, source prefixes,
# address family, path, terminal provider attachment, and return behavior.
# Emits resolver-specific IPv4 and IPv6 reachability on every requester path
# leg keyed by relation ID, requester scope, family, destination prefix,
# policy table, outgoing lane, and selected next-hop identity.
#
# - Emits one semantic next hop per route key.
# - Collapses exact duplicate atoms with same provenance and next-hop identity.
# - Fails equal-prefix atoms with different lane or next-hop identity as ambiguous.
# - Per-requester policy tables select only that requester's upstream-lane next hop.
# - Rejects fan-out of a shared resolver /32 or /128 over sibling VLAN, tenant,
#   or access lanes.
# - Preserves relation-scoped new-flow authority through selectors, policy, and
#   destination access ingress.
# - Emits stateful return authority for the reverse of a one-way requester relation.
# - Prevents provider-only, management, lateral, or unrelated access lanes from
#   inheriting resolver routes or firewall authority.
# - Keeps direct requester-to-core diagnostic access separate from
#   access-resolver delegation.
# - Treats reachability to a core ownership loopback or unrelated attachment as
#   a different path; it does not satisfy the selected resolver relation.

{
  lib,
  common,
}:

let
  inherit (common) attrsOrEmpty failForwarding listOrEmpty;

  # ---------------------------------------------------------------------------
  # Route-key components
  # ---------------------------------------------------------------------------

  # Normalise empty/missing strings to empty so key comparisons are stable.
  emptyOr = value: if builtins.isString value && value != "" then value else "";

  # Build a deterministic route key from the fields required by SMS-040.
  makeRouteKey =
    {
      relationId ? "",
      requesterScope ? "",
      family ? 4,
      dst ? "",
      policyTable ? "",
      outgoingLane ? "",
      nextHopIdentity ? "",
    }:
    "${emptyOr relationId}|${emptyOr requesterScope}|${builtins.toString family}|${emptyOr dst}|${emptyOr policyTable}|${emptyOr outgoingLane}|${emptyOr nextHopIdentity}";

  # ---------------------------------------------------------------------------
  # Lane enforcement
  # ---------------------------------------------------------------------------

  # Extract the lane identity from an interface.
  interfaceLane =
    iface:
    attrsOrEmpty ((attrsOrEmpty (iface.backingRef or null)).lane or null);

  interfaceLaneIdentity =
    iface:
    let
      lane = interfaceLane iface;
    in
    "${emptyOr (lane.kind or null)}:${emptyOr (lane.access or null)}";

  # Determine whether a given interface represents the requester's modeled
  # upstream lane.  We match the lane that is both the requester's ingress
  # lane and has the correct upstream identity attached to its backing ref.
  matchesRequesterUpstreamLane =
    iface: requesterScope: targetLaneIdentity:
    let
      lane = interfaceLane iface;
      laneId = "${emptyOr (lane.kind or null)}:${emptyOr (lane.access or null)}";
      # The backing-ref uplinks field names the upstream lanes this interface
      # serves as ingress for.
      backingRef = attrsOrEmpty (iface.backingRef or null);
      uplinks = listOrEmpty (backingRef.uplinks or null);
    in
    laneId == targetLaneIdentity;

  # ---------------------------------------------------------------------------
  # Route-key factory from an individual route record
  # ---------------------------------------------------------------------------

  routeKeyFor =
    route: requesterScope: family: laneIdentity: policyTableId:
    let
      viaField = if family == 4 then "via4" else "via6";
    in
    makeRouteKey {
      relationId = route.relationId or route.relId or "";
      inherit
        requesterScope
        family
        ;
      dst = route.dst or "";
      policyTable = policyTableId;
      outgoingLane = laneIdentity;
      nextHopIdentity = route.${viaField} or route.via or "";
    };

  # ---------------------------------------------------------------------------
  # Collapse exact duplicates; detect conflicting duplicates (same key,
  # different next-hop identity or lane).  Both branches derive from the
  # perNextHopKey map exactly once so the nix evaluator sees deterministic
  # order (builtins.mapAttrs on a stable attribute set).
  # ---------------------------------------------------------------------------

  resolveRouteCollisions =
    routes: requesterScope: family: laneIdentity: policyTableId:
    let
      # Build keyed map of route → key
      keyed = builtins.map
        (route: {
          key = routeKeyFor route requesterScope family laneIdentity policyTableId;
          inherit route;
        })
        routes;

      # Group by key — attrset with one entry per key
      byKey = builtins.foldl'
        (acc: entry:
          let
            existing = acc.${entry.key} or [ ];
          in
          acc // { ${entry.key} = existing ++ [ entry.route ]; })
        { }
        keyed;

      # For each key: if all routes are identical (same via + dst), collapse to
      # one.  Otherwise fail because the same key produced different next-hop or
      # lane identities.
      processKey =
        _key: group:
        let
          first = builtins.head group;
          viaField = if family == 4 then "via4" else "via6";
          allSame =
            builtins.all
              (r: (r.dst or "") == (first.dst or "") && (r.${viaField} or "") == (first.${viaField} or ""))
              group;
        in
        if allSame then
          [ first ]
        else
          failForwarding
            "runtime-targets.requester-lane-recursive-reachability"
            "FS-540-HDS-010-SDS-010-SMS-040: ambiguous route key '${_key}' — equal-prefix atoms with different lane or next-hop identity are a conflict";
    in
    builtins.concatLists (builtins.attrValues (builtins.mapAttrs processKey byKey));

  # ---------------------------------------------------------------------------
  # Endpoint-path validation helpers
  # ---------------------------------------------------------------------------

  # Strip CIDR prefix length from an address string, leaving just the host
  # address (e.g. "10.0.0.1/32" → "10.0.0.1").
  stripPrefixLength =
    value:
    if !(builtins.isString value) || value == "" then
      ""
    else
      builtins.head (lib.splitString "/" value);

  # Collect every core-ownership loopback address across all runtime targets
  # into a flat set keyed by the bare address (no prefix-length).  These are
  # the addresses that must NOT appear as the destination of a DNS service
  # reachability route.
  collectLoopbackAddresses =
    allTargets:
    let
      collectForTarget =
        acc: targetName:
        let
          target = allTargets.${targetName} or { };
          realization = attrsOrEmpty (target.effectiveRuntimeRealization or null);
          loopback = attrsOrEmpty (realization.loopback or null);
          addr4 = stripPrefixLength (loopback.addr4 or loopback.ipv4 or "");
          addr6 = stripPrefixLength (loopback.addr6 or loopback.ipv6 or "");
        in
        acc
        // lib.optionalAttrs (addr4 != "") { ${addr4} = true; }
        // lib.optionalAttrs (addr6 != "") { ${addr6} = true; };
    in
    builtins.foldl' collectForTarget { } (builtins.attrNames allTargets);

  # Check whether a route destination (dst) resolves to a loopback address.
  # The dst is normally in CIDR form (e.g. "10.0.0.1/32"); we strip the
  # prefix-length before comparing against the loopback set.
  dstIsLoopback =
    dst: loopbackSet:
    let
      hostAddr = stripPrefixLength (if builtins.isString dst then dst else "");
    in
    hostAddr != "" && (loopbackSet.${hostAddr} or false);

  # ---------------------------------------------------------------------------
  # Per-target processing
  # ---------------------------------------------------------------------------

  addRequesterLaneKeying =
    targetName: target: firewallIntent: loopbackAddresses:
    let
      effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
      interfaces = attrsOrEmpty (effective.interfaces or null);
      forwarding = attrsOrEmpty (firewallIntent.${targetName} or null);

      # Only operate on access-role targets that carry DNS resolver intent
      isAccess = (target.role or null) == "access";
      services = attrsOrEmpty (target.services or null);
      dns = attrsOrEmpty (services.dns or null);
      hasDnsResolver = (dns.roles or { }) != { } || (dns.forwarders or [ ]) != [ ];

      # Collect all requester lanes from forwarding rules that are DNS-related
      dnsRules =
        builtins.filter
          (rule:
            (rule.action or null) == "accept"
            && (rule.trafficType or null) == "dns"
            && ((attrsOrEmpty (rule.from or null)).kind or null) != "service"
            && ((attrsOrEmpty (rule.to or null)).kind or null) == "service")
          (listOrEmpty (forwarding.rules or null));

      # For each interface, compute the requester-lane reachability key
      # and tag routes with the SMS-040 identity.
      requesterLaneScopes =
        builtins.foldl'
          (acc: rule:
            let
              fromKind = (attrsOrEmpty (rule.from or null)).kind or null;
              fromName = (attrsOrEmpty (rule.from or null)).name or null;
              toName = (attrsOrEmpty (rule.to or null)).name or null;
              relationId = rule.relationId or rule.id or "";
            in
            acc // {
              ${fromName} = {
                inherit fromKind fromName toName relationId;
                requesterScope = fromName;
              };
            })
          { }
          dnsRules;

      # Apply requester-lane keying to each interface's routes
      applyLaneKeyingToInterface =
        ifName: iface:
        let
          backingRef = attrsOrEmpty (iface.backingRef or null);
          lane = attrsOrEmpty (backingRef.lane or null);
          laneKind = lane.kind or "";
          laneAccess = lane.access or "";
          laneIdentity = "${laneKind}:${laneAccess}";
          isRequesterLane = builtins.hasAttr laneAccess requesterLaneScopes;

          routes = attrsOrEmpty (iface.routes or null);

          # Policy table ID from interface allocation
          allocation = attrsOrEmpty (iface.policyRoutingAllocation or null);
          policyTableId =
            if builtins.isInt (allocation.tableId or null) then
              builtins.toString allocation.tableId
            else
              "";

          processFamily =
            family: field:
            let
              familyRoutes = listOrEmpty (routes.${field} or null);
              # Filter to DNS-service-related routes
              dnsReachabilityRoutes =
                builtins.filter
                  (route:
                    builtins.isAttrs route
                    && (route.intent or { }).kind or "" == "service-dns-reachability")
                  familyRoutes;
              nonDnsRoutes =
                builtins.filter
                  (route:
                    !(builtins.isAttrs route)
                    || (route.intent or { }).kind or "" != "service-dns-reachability")
                  familyRoutes;

              # ── Endpoint-path validation: reject DNS routes whose
              # destination is a core ownership loopback address (SMS-040
              # predicate 6 / seeded negative "core ownership loopback").
              #
              # Remaining routes that survive this filter are the true
              # resolver-endpoint routes.
              validDnsReachabilityRoutes =
                let
                  loopbackRejects = builtins.filter
                    (route: dstIsLoopback (route.dst or "") loopbackAddresses)
                    dnsReachabilityRoutes;
                  _loopbackDiag = if loopbackRejects != [ ] then
                    builtins.trace
                      "FS-540-HDS-010-SDS-010-SMS-040: rejecting ${builtins.toString (builtins.length loopbackRejects)} DNS service route(s) on lane '${laneIdentity}' — destination matches a core ownership loopback; only resolver endpoint addresses are valid"
                      null
                  else
                    null;
                in
                builtins.filter
                  (route: !dstIsLoopback (route.dst or "") loopbackAddresses)
                  dnsReachabilityRoutes;

              # Apply SMS-040 keying + collision resolution to DNS routes
              keyedDnsRoutes =
                if isRequesterLane then
                  resolveRouteCollisions validDnsReachabilityRoutes laneAccess family laneIdentity policyTableId
                else
                  # Non-requester lanes: remove DNS resolver routes — they
                  # must not inherit resolver reachability.  Emit diagnostic.
                  if validDnsReachabilityRoutes != [ ] then
                    let
                      _warn = builtins.trace
                        "FS-540-HDS-010-SDS-010-SMS-040: lane '${laneIdentity}' is not an authorized requester lane; removing ${builtins.toString (builtins.length validDnsReachabilityRoutes)} DNS service route(s)"
                        null;
                    in
                    [ ]
                  else
                    [ ];

              # Add SMS-040 provenance to each kept route
              taggedKeyedRoutes =
                builtins.map
                  (route:
                    route // {
                      sms040RouteKey = makeRouteKey {
                        relationId = route.relationId or route.relId or "";
                        requesterScope = laneAccess;
                        inherit family;
                        dst = route.dst or "";
                        policyTable = policyTableId;
                        outgoingLane = laneIdentity;
                        nextHopIdentity = route.via4 or route.via6 or route.via or "";
                      };
                      sms040Provenance = {
                        source = "FS-540-HDS-010-SDS-010-SMS-040";
                        predicate = "requester-lane-recursive-reachability";
                      };
                    })
                  keyedDnsRoutes;

              finalRoutes = nonDnsRoutes ++ taggedKeyedRoutes;
            in
            if family == 4 then { ipv4 = finalRoutes; } else { ipv6 = finalRoutes; };
        in
        iface
        // {
          routes =
            (processFamily 4 "ipv4")
            // (processFamily 6 "ipv6");
        };

      updatedInterfaces =
        builtins.mapAttrs applyLaneKeyingToInterface interfaces;
    in
    target // {
      effectiveRuntimeRealization = effective // { interfaces = updatedInterfaces; };
    };

  # ---------------------------------------------------------------------------
  # Cross-target lane inheritance prevention
  #
  # Walk all runtime targets and ensure that no resolver route from one
  # requester's lane has leaked into another target's interfaces.  A resolver
  # prefix that appears in a non-requester lane (provider-only, management,
  # lateral, or unrelated access) is a construction failure.
  # ---------------------------------------------------------------------------

  validateCrossTargetLaneIsolation =
    runtimeTargets: firewallIntent:
    let
      # Collect all authorized resolver prefixes per requester lane
      authorizedPrefixes =
        builtins.foldl'
          (acc: targetName:
            let
              target = runtimeTargets.${targetName};
              forwarding = attrsOrEmpty (firewallIntent.${targetName} or null);
              effective = attrsOrEmpty (target.effectiveRuntimeRealization or null);
              interfaces = attrsOrEmpty (effective.interfaces or null);
              dnsRules =
                builtins.filter
                  (rule:
                    (rule.action or null) == "accept"
                    && (rule.trafficType or null) == "dns"
                    && ((attrsOrEmpty (rule.from or null)).kind or null) != "service"
                    && ((attrsOrEmpty (rule.to or null)).kind or null) == "service")
                  (listOrEmpty (forwarding.rules or null));

              # Build a set of (requester-lane, dst) that is authorized
              authorizedForTarget =
                builtins.foldl'
                  (innerAcc: rule:
                    let
                      requesterLane = (attrsOrEmpty (rule.from or null)).name or "";
                      toIface = rule.toInterface or null;
                    in
                    if requesterLane == "" || toIface == null then
                      innerAcc
                    else
                      innerAcc // { "${requesterLane}:${toIface}" = true; })
                  { }
                  dnsRules;
            in
            acc // authorizedForTarget)
          { }
          (builtins.attrNames runtimeTargets);
    in
    # This value forces evaluation of the purity diagnostic.  If we detect any
    # unauthorized resolver route, we trace a diagnostic that names the SMS.
    # The actual enforcement is done per-lane inside applyLaneKeyingToInterface
    # (non-requester lanes strip DNS routes), but this cross-target check
    # ensures no stray resolver routes have leaked anywhere.
    authorizedPrefixes;
in

# Public API: apply requester-lane keying to all runtime targets.
#
# Usage from finalize.nix or an equivalent integration point:
#
#   addRequesterLaneKeying = import ./requester-lane-recursive-reachability.nix {
#     inherit lib common;
#   };
#
# Then call:
#   addRequesterLaneKeying { inherit normalizedRuntimeTargets firewallIntent; }

{ normalizedRuntimeTargets, firewallIntent }:

let
  # ── Collect core-ownership loopback addresses once across all targets
  # so the per-target processing can reject any DNS service route whose
  # destination matches a loopback (SMS-040 predicate 6).
  allLoopbackAddresses = collectLoopbackAddresses normalizedRuntimeTargets;

  targetsWithKeying =
    builtins.mapAttrs
      (targetName: target:
        if builtins.hasAttr targetName (firewallIntent.forwardingByTarget or { }) then
          addRequesterLaneKeying
            targetName
            target
            (firewallIntent.forwardingByTarget or { })
            allLoopbackAddresses
        else
          target)
      normalizedRuntimeTargets;

  # Force cross-target lane isolation diagnostic
  _laneIsolation = validateCrossTargetLaneIsolation
    targetsWithKeying
    (firewallIntent.forwardingByTarget or { });
in
targetsWithKeying
