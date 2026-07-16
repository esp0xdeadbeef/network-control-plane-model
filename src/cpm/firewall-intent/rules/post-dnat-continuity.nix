{ common }:

# FS-270-HDS-010-SDS-010-SMS-010: post-DNAT hop-continuity evaluation.
#
# A post-DNAT public-ingress flow is the SAME modeled payload tuple through
# every selector, policy, access, and target-facing hop. DNAT plus a bounded
# translation-owner forward rule on the translation owner is not enough: the
# translated tuple must independently prove, at EVERY modeled hop,
#   1. route lookup   — an exact target route for the tuple destination exists
#                       in the table the hop's route policy selects,
#   2. policy table   — the selected table is a table the modeled route policy
#                       authorizes for this tuple (main or a modeled policy
#                       table), never an unmodeled table,
#   3. next hop       — the matched route's next hop is the modeled adjacency
#                       of the following hop (or direct delivery on the
#                       target-facing hop),
#   4. tuple authority — a forwarding rule at the hop authorizes the tuple
#                       with enforceable packet matches (protocol + port) or
#                       carries complete isolated transport authority
#                       (transportAuthority basis = dedicated-link-isolation,
#                       admissible, provenanceIsAuthority = false).
#
# Each precondition is evaluated independently per hop; the evaluator emits
# the exact target route, selected main/policy table, next hop, and tuple
# forwarding precondition for each hop, and identifies the FIRST broken hop
# when continuity fails. The path is rejected fail-closed.
#
# Explicitly NOT tuple authority (SMS Negative case 5 non-recovery):
#   - a generic interface-pair accept (trafficType = "any" or absent) with no
#     enforceable matches and no admissible dedicated-link-isolation
#     authority — topology provenance labels never authorize the tuple;
#   - a stateful return rule (returnRule = true) — reply-direction authority
#     never authorizes the forward tuple;
#   - any non-accept rule.
#
# Boundary: exact-route containment is evaluated with IPv4 prefix math
# (production post-DNAT ingress case). IPv6 routes match by exact modeled
# host-route/prefix string equality only; no broad-prefix IPv6 inference is
# performed here.

let
  listOrEmpty = value: if builtins.isList value then value else [ ];
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  isNonEmptyString = value: builtins.isString value && value != "";

  # --- minimal IPv4 prefix containment (self-contained: the rules layer is
  # dependency-free and must stay evaluable without nixpkgs lib) ------------
  splitDots = value: builtins.filter builtins.isString (builtins.split "\\." value);

  parseIPv4 = value:
    let
      parts = splitDots value;
      nums = map builtins.fromJSON parts;
      valid =
        builtins.length parts == 4
        && builtins.all (part: builtins.match "[0-9]+" part != null) parts
        && builtins.all (n: n >= 0 && n <= 255) nums;
    in
    if builtins.isString value && builtins.match "[0-9.]+" value != null && valid then
      builtins.elemAt nums 0 * 16777216
      + builtins.elemAt nums 1 * 65536
      + builtins.elemAt nums 2 * 256
      + builtins.elemAt nums 3
    else
      null;

  pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);

  splitCidr = value:
    let
      parts = builtins.filter builtins.isString (builtins.split "/" value);
    in
    if builtins.isString value && builtins.length parts == 2 then
      let
        addr = parseIPv4 (builtins.elemAt parts 0);
        lenPart = builtins.elemAt parts 1;
        len =
          if builtins.match "[0-9]+" lenPart != null then
            builtins.fromJSON lenPart
          else
            null;
      in
      if addr != null && len != null && len >= 0 && len <= 32 then
        {
          inherit addr len;
        }
      else
        null
    else
      null;

  networkBase = addr: len:
    let
      block = pow2 (32 - len);
    in
    (builtins.div addr block) * block;

  ipv4CidrContains = cidr: address:
    let
      parsed = splitCidr cidr;
      addr = parseIPv4 address;
    in
    parsed != null
    && addr != null
    && networkBase addr parsed.len == networkBase parsed.addr parsed.len;

  isIpv6 = value: builtins.isString value && builtins.match ".*:.*" value != null;

  routeDstLen = dst:
    let
      parsed = splitCidr dst;
    in
    if parsed != null then parsed.len else -1;

  routeCoversDestination = tuple: route:
    let
      dst = (attrsOrEmpty route).dst or null;
    in
    if !(isNonEmptyString dst) then
      false
    else if isIpv6 (tuple.dstAddress or "") || isIpv6 dst then
      # IPv6 boundary: exact modeled host route / prefix string only.
      dst == "${tuple.dstAddress}/128" || dst == tuple.dstAddress
    else
      ipv4CidrContains dst tuple.dstAddress;

  # --- tuple forwarding authority ------------------------------------------
  matchCoversTuple = tuple: match:
    let
      m = attrsOrEmpty match;
      proto = m.proto or null;
      dports = listOrEmpty (m.dports or null);
      family = m.family or "any";
      familyOk =
        family == "any"
        || (builtins.isInt family && family == (tuple.family or 4))
        || family == builtins.toString (tuple.family or 4);
    in
    proto == (tuple.protocol or null)
    && familyOk
    && (dports == [ ] || builtins.elem (tuple.dstPort or null) dports);

  ruleTupleAuthority = tuple: rule:
    let
      r = attrsOrEmpty rule;
      authority = attrsOrEmpty (r.transportAuthority or null);
      matches = listOrEmpty (r.matches or null);
      enforceableMatch =
        builtins.any (matchCoversTuple tuple) matches;
      isolatedTransport =
        (authority.basis or null) == "dedicated-link-isolation"
        && (authority.admissible or false) == true
        && (authority.provenanceIsAuthority or true) == false;
    in
    if (r.action or null) != "accept" then
      null
    else if (r.returnRule or false) == true then
      # Reply-direction authority never authorizes the forward tuple.
      null
    else if enforceableMatch then
      {
        satisfied = true;
        basis = "enforceable-matches";
      }
    else if isolatedTransport then
      {
        satisfied = true;
        basis = "isolated-transport-authority";
      }
    else
      # Generic interface-pair accept: provenance labels (relationId,
      # comment, nonBypass, trafficType=any) are not tuple authority.
      null;

  tupleForwardingFor = tuple: hop:
    let
      grants =
        builtins.filter (grant: grant != null)
          (map (ruleTupleAuthority tuple) (listOrEmpty (hop.rules or null)));
    in
    if grants != [ ] then
      builtins.head grants
    else
      {
        satisfied = false;
        basis = null;
        diagnostic = "route-without-tuple-allow";
      };

  # --- per-hop evaluation (each precondition independent) ------------------
  evaluateHop = tuple: hop: nextHopAdjacency:
    let
      name = hop.name or "unnamed-hop";
      selectedTable = hop.selectedTable or "main";
      authorizedTables =
        let
          tables = listOrEmpty (hop.authorizedTables or null);
        in
        if tables == [ ] then [ "main" ] else tables;
      tableAuthorized = builtins.elem selectedTable authorizedTables;

      candidateRoutes =
        builtins.filter
          (route:
            ((attrsOrEmpty route).table or "main") == selectedTable
            && routeCoversDestination tuple route)
          (listOrEmpty (hop.routes or null));

      targetRoute =
        if candidateRoutes == [ ] then
          null
        else
          builtins.head (
            builtins.sort
              (a: b: routeDstLen (a.dst or "") > routeDstLen (b.dst or ""))
              candidateRoutes
          );

      routeFound = targetRoute != null;
      routeNextHop = if routeFound then targetRoute.nextHop or null else null;
      targetFacing = (hop.targetFacing or false) == true;
      expectedNextHop =
        if hop ? expectedNextHop then hop.expectedNextHop else nextHopAdjacency;
      nextHopContinuous =
        routeFound
        && (
          if targetFacing then
            routeNextHop == null
            || routeNextHop == ""
            || routeNextHop == tuple.dstAddress
          else
            isNonEmptyString expectedNextHop && routeNextHop == expectedNextHop
        );

      tupleForwarding = tupleForwardingFor tuple hop;

      missing =
        (if routeFound then [ ] else [ "missing-target-route" ])
        ++ (if tableAuthorized then [ ] else [ "wrong-policy-table" ])
        ++ (if routeFound && !nextHopContinuous then [ "wrong-next-hop" ] else [ ])
        ++ (if tupleForwarding.satisfied then [ ] else [ "route-without-tuple-allow" ]);
    in
    {
      hop = name;
      inherit selectedTable targetRoute tupleForwarding missing;
      nextHop = routeNextHop;
      preconditions = {
        inherit routeFound tableAuthorized;
        nextHopContinuous = routeFound && nextHopContinuous;
        tupleAuthorized = tupleForwarding.satisfied;
      };
      ok = missing == [ ];
    };

  tupleComplete = tuple:
    isNonEmptyString (tuple.protocol or null)
    && isNonEmptyString (tuple.dstAddress or null)
    && builtins.isInt (tuple.dstPort or null);
in

{ tuple
, hops
}:
let
  tupleRecord = {
    family = tuple.family or 4;
    protocol = tuple.protocol or null;
    dstAddress = tuple.dstAddress or null;
    dstPort = tuple.dstPort or null;
    translationOwner = tuple.translationOwner or null;
  };

  hopList = listOrEmpty hops;
  hopCount = builtins.length hopList;

  adjacencyFor = index:
    if index + 1 < hopCount then
      (builtins.elemAt hopList (index + 1)).hopAddress or null
    else
      null;

  hopRecords =
    builtins.genList
      (index: evaluateHop tupleRecord (builtins.elemAt hopList index) (adjacencyFor index))
      hopCount;

  brokenRecords = builtins.filter (record: !record.ok) hopRecords;

  base = {
    module = "FS-270-HDS-010-SDS-010-SMS-010";
    kind = "post-dnat-hop-continuity";
    tuple = tupleRecord;
    inherit hopRecords;
  };
in
if !(tupleComplete (attrsOrEmpty tuple)) then
  # Unknown/unclassified translated tuple: reject, never fall back to a
  # broad accept.
  base
  // {
    continuous = false;
    firstBrokenHop = null;
    failClosed = true;
    diagnostic = {
      code = "post-dnat-tuple-incomplete";
      failClosed = true;
      tuple = tupleRecord;
    };
  }
else if hopCount == 0 then
  base
  // {
    continuous = false;
    firstBrokenHop = null;
    failClosed = true;
    diagnostic = {
      code = "post-dnat-no-modeled-hops";
      failClosed = true;
    };
  }
else if brokenRecords != [ ] then
  let
    firstBroken = builtins.head brokenRecords;
  in
  base
  // {
    continuous = false;
    firstBrokenHop = firstBroken.hop;
    failClosed = true;
    diagnostic = {
      code = "post-dnat-continuity-broken";
      hop = firstBroken.hop;
      missing = firstBroken.missing;
      failClosed = true;
    };
  }
else
  base
  // {
    continuous = true;
    firstBrokenHop = null;
    failClosed = false;
    diagnostic = null;
  }
