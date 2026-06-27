{ repoRoot }:
let
  common = import (repoRoot + "/src/cpm/firewall-intent/rules/common.nix") { };

  mockEndpointIfaces = relation: endpoint: peerEndpoint:
    [ { runtimeIfName = "ens20";
        backingRef = { lane = { kind = "access"; access = "client"; }; };
      } ];
  mockEndpointIfacesForPeerAccess = relation: endpoint: peerEndpoint: access:
    [ { runtimeIfName = "ens21";
        backingRef = { lane = { kind = "policy"; }; };
      } ];

  attrsOrEmpty = value: if builtins.isAttrs value then value else { };

  mockRelationMatches = relation:
    if builtins.isList (relation.matches or null) then relation.matches
    else [ { proto = "tcp"; dport = 443; } ];

  withRelationSourceScope = relation: rule: common.withSourcePrefixes rule [];

  relationId = relation:
    if builtins.isString (relation.id or null) && relation.id != "" then relation.id
    else if builtins.isString (relation.name or null) && relation.name != "" then relation.name
    else null;

  relationRules = relationRaw:
    let
      relation = attrsOrEmpty relationRaw;
      action = if (relation.action or "allow") == "deny" then "deny" else "accept";
      id = relationId relation;

      buildDirectionRules = { direction, fromEndpoint, toEndpoint, reverseSource ? false }:
        let
          fromIfaces = mockEndpointIfaces relation fromEndpoint toEndpoint;
          relationForSource = if reverseSource then
            relation // { from = attrsOrEmpty toEndpoint; to = attrsOrEmpty fromEndpoint; }
          else relation;
          ruleEndpointFrom = attrsOrEmpty fromEndpoint;
          ruleEndpointTo = attrsOrEmpty toEndpoint;
        in builtins.concatLists (
          map (fromIface:
            let toIfaces = mockEndpointIfacesForPeerAccess relation toEndpoint fromEndpoint (common.laneAccess fromIface);
            in map (toIface:
              withRelationSourceScope relationForSource {
                inherit action;
                relationId = id;
                comment = id;
                priority = relation.priority or null;
                trafficType = relation.trafficType or "any";
                inherit direction;
                matches = mockRelationMatches relation;
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
            ) toIfaces
          ) fromIfaces
        );

      forwardRules = buildDirectionRules {
        direction = "relation-forward";
        fromEndpoint = relation.from or null;
        toEndpoint = relation.to or null;
      };
      reverseRules = if (relation.returnBehavior or null) == "symmetric" then
        buildDirectionRules {
          direction = "relation-reverse";
          fromEndpoint = relation.to or null;
          toEndpoint = relation.from or null;
          reverseSource = true;
        }
      else [ ];
    in forwardRules ++ reverseRules;

  # Test fixtures: production-shaped relations reflecting post-NFM-fix state
  # NFM HEAD 5febabe injects returnBehavior=symmetric on ALL non-tenant-to-tenant
  # allow relations regardless of trafficType.

  # P1: trafficType="any" tenant->external (was covered by old NFM)
  rel_any_t2e = {
    action = "allow";
    id = "rel-any-tenant-to-external";
    from = { kind = "tenant-set"; name = "clients"; };
    to = { kind = "external"; uplinks = [ "wan" ]; };
    trafficType = "any";
    returnBehavior = "symmetric";
  };

  # P2: trafficType="dns" service->external (D18-NEW: was missed)
  rel_dns_s2e = {
    action = "allow";
    id = "rel-dns-service-to-external";
    from = { kind = "service"; name = "site-dns"; };
    to = { kind = "external"; uplinks = [ "wan" ]; };
    trafficType = "dns";
    returnBehavior = "symmetric";
  };

  # P3: trafficType="icmp" external->tenant (D18-NEW: was missed)
  rel_icmp_e2t = {
    action = "allow";
    id = "rel-icmp-external-to-tenant";
    from = { kind = "external"; uplinks = [ "wan" ]; };
    to = { kind = "tenant-set"; members = [ "client" ]; };
    trafficType = "icmp";
    returnBehavior = "symmetric";
  };

  # P4: trafficType="nebula" tenant->external (overlay-control, D18-NEW)
  rel_nebula_t2e = {
    action = "allow";
    id = "rel-nebula-tenant-to-external";
    from = { kind = "tenant-set"; members = [ "dmz" ]; };
    to = { kind = "external"; name = "east-west"; };
    trafficType = "nebula";
    returnBehavior = "symmetric";
  };

  # P5: trafficType="ipp" tenant->service (printer-admin, D18-NEW)
  rel_ipp_t2s = {
    action = "allow";
    id = "rel-ipp-tenant-to-service";
    from = { kind = "tenant-set"; members = [ "admin" ]; };
    to = { kind = "service"; name = "printer"; };
    trafficType = "ipp";
    returnBehavior = "symmetric";
  };

  # N1: tenant-to-tenant -- one-way (no symmetric per FS-640/FS-620)
  rel_tenant2tenant = {
    action = "allow";
    id = "rel-tenant-to-tenant";
    from = { kind = "tenant-set"; members = [ "mgmt" ]; };
    to = { kind = "tenant-set"; members = [ "client" ]; };
    trafficType = "any";
  };

  # N2: explicit returnBehavior="one-way" -- preserved
  rel_explicit_oneway = {
    action = "allow";
    id = "rel-explicit-oneway";
    from = { kind = "tenant-set"; members = [ "client" ]; };
    to = { kind = "external"; uplinks = [ "wan" ]; };
    trafficType = "any";
    returnBehavior = "one-way";
  };

  # Execute
  rules_any_t2e = relationRules rel_any_t2e;
  rules_dns_s2e = relationRules rel_dns_s2e;
  rules_icmp_e2t = relationRules rel_icmp_e2t;
  rules_nebula_t2e = relationRules rel_nebula_t2e;
  rules_ipp_t2s = relationRules rel_ipp_t2s;
  rules_tt = relationRules rel_tenant2tenant;
  rules_oneway = relationRules rel_explicit_oneway;

  fwd = rules: builtins.filter (r: r.direction == "relation-forward") rules;
  rev = rules: builtins.filter (r: r.direction == "relation-reverse") rules;
  fwdCount = rules: builtins.length (fwd rules);
  revCount = rules: builtins.length (rev rules);

in {
  p1_any_fwd = fwdCount rules_any_t2e == 1;
  p1_any_rev = revCount rules_any_t2e == 1;
  p1_any_total = builtins.length rules_any_t2e == 2;
  p2_dns_fwd = fwdCount rules_dns_s2e == 1;
  p2_dns_rev = revCount rules_dns_s2e == 1;
  p2_dns_total = builtins.length rules_dns_s2e == 2;
  p3_icmp_fwd = fwdCount rules_icmp_e2t == 1;
  p3_icmp_rev = revCount rules_icmp_e2t == 1;
  p3_icmp_total = builtins.length rules_icmp_e2t == 2;
  p4_nebula_fwd = fwdCount rules_nebula_t2e == 1;
  p4_nebula_rev = revCount rules_nebula_t2e == 1;
  p4_nebula_total = builtins.length rules_nebula_t2e == 2;
  p5_ipp_fwd = fwdCount rules_ipp_t2s == 1;
  p5_ipp_rev = revCount rules_ipp_t2s == 1;
  p5_ipp_total = builtins.length rules_ipp_t2s == 2;
  n1_tt_fwd = fwdCount rules_tt == 1;
  n1_tt_rev = revCount rules_tt == 0;
  n1_tt_total = builtins.length rules_tt == 1;
  n2_ow_fwd = fwdCount rules_oneway == 1;
  n2_ow_rev = revCount rules_oneway == 0;
  n2_ow_total = builtins.length rules_oneway == 1;
  any_rev_ok = builtins.length (rev rules_any_t2e) > 0
    && ((builtins.head (rev rules_any_t2e)).direction or "") == "relation-reverse"
    && ((builtins.head (rev rules_any_t2e)).relationId or null) == "rel-any-tenant-to-external";
}
