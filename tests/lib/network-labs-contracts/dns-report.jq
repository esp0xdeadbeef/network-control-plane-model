include "common";

def site_has_dns_intent($site):
  ([($site.data.relations // [])[] | select((.trafficType // "") == "dns")] | length) > 0
  or ([($site.data.services // [])[] | select((.trafficType // "") == "dns")] | length) > 0;

def site_dns_targets($site):
  [runtime_targets($site) | select((.data.services.dns // null) != null)];

def missing_site_dns_contract_violations:
  sites
  | select(site_has_dns_intent(.))
  | select((site_dns_targets(.) | length) == 0)
  | violation("dns-contract"; .name; .enterprise; .site; ""; "site has DNS intent but no runtime target emits services.dns");

def dns_contract_violations:
  sites as $site
  | runtime_targets($site)
  | select((.data.services.dns // null) != null)
  | . as $target
  | ($target.data.services.dns // {}) as $dns
  | ($dns.forwarders // []) as $forwarders
  | ($forwarders | map(. as $forwarder | select(public_resolvers | index($forwarder) != null))) as $publicForwarders
  | ($dns.killSwitch // {}) as $killSwitch
  | if ($dns.implementation // "") != "unbound" then
      violation("dns-contract"; $target.name; $target.enterprise; $target.site; $target.id; "DNS contract must explicitly select unbound")
    elif ($target.data.role // "") == "access" and ($dns.routePreference // []) != expected_dns_route_preference then
      violation("dns-contract"; $target.name; $target.enterprise; $target.site; $target.id; "access DNS routePreference is not deterministic")
    elif ($killSwitch.enabled // false) != true then
      violation("dns-contract"; $target.name; $target.enterprise; $target.site; $target.id; "DNS kill-switch is not enabled")
    elif ($killSwitch.blockPublicResolvers // false) != true then
      violation("dns-contract"; $target.name; $target.enterprise; $target.site; $target.id; "DNS public resolver block is not enabled")
    elif ($killSwitch.blockImplicitDefaultRouteDns // false) != true then
      violation("dns-contract"; $target.name; $target.enterprise; $target.site; $target.id; "DNS implicit default-route block is not enabled")
    elif ($killSwitch.allowPublicResolverFallback // true) != false then
      violation("dns-contract"; $target.name; $target.enterprise; $target.site; $target.id; "DNS public resolver fallback is allowed")
    elif ($target.data.role // "") == "access" and ($dns.routeContracts // [] | length) == 0 then
      violation("dns-contract"; $target.name; $target.enterprise; $target.site; $target.id; "access DNS forwarders lack explicit route contracts")
    elif ($target.data.role // "") == "access" and ($dns.policyMatrix // [] | length) == 0 then
      violation("dns-contract"; $target.name; $target.enterprise; $target.site; $target.id; "access DNS lacks compiled policy matrix evidence")
    elif ($publicForwarders | length) > 0 and ((($dns.allowedUpstreamClasses // []) | index("explicit-egress-default")) == null) then
      violation("dns-contract"; $target.name; $target.enterprise; $target.site; $target.id; "public DNS forwarder lacks explicit egress class")
    else empty end;

def has_dst($routes; $destination):
  ([($routes.ipv4 // [])[] | select((.dst // "") == $destination)] | length) > 0
  or ([($routes.ipv6 // [])[] | select((.dst // "") == $destination)] | length) > 0;

def access_dns_route_violations:
  sites as $site
  | runtime_targets($site)
  | select((.data.role // "") == "access")
  | . as $target
  | ($target.data.services.dns.forwarders // []) as $forwarders
  | ($target.data.effectiveRuntimeRealization.interfaces // {})
  | to_entries[]
  | select((.value.sourceKind // "") == "p2p")
  | . as $iface
  | [
      $forwarders[]
      | select(has_dst(($iface.value.routes // {}); .) | not)
    ] as $missing
  | select(($missing | length) > 0)
  | violation("access-dns-route"; $target.name; $target.enterprise; $target.site; $target.id; "access p2p " + ($iface.value.runtimeIfName // $iface.key) + " lacks explicit routes to DNS forwarders: " + ($missing | join(",")));

missing_site_dns_contract_violations,
dns_contract_violations,
access_dns_route_violations
