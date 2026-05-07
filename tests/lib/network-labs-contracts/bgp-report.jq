include "common";

def bgp_policy_rr_violations:
  sites
  | select((.data.routing.mode // "static") == "bgp") as $site
  | router_targets($site) as $routers
  | ($routers | map(select(.role == "policy"))) as $policies
  | ($policies[0] // null) as $policy
  | (
      if ($policies | length) != 1 then
        violation("bgp-policy-rr"; $site.name; $site.enterprise; $site.site; ""; "BGP site must have exactly one policy route reflector")
      else empty end
    ),
    (
      $routers[]
      | . as $router
      | if $router.bgp == null then
          violation("bgp-router"; $site.name; $site.enterprise; $site.site; $router.node; "router target in BGP site is missing bgp object")
        else
          ($router.bgp.neighbors // [])[]
          | . as $neighbor
          | ($routers | map(.node) | index($neighbor.peer_name // "")) as $peerIndex
          | if $peerIndex == null and ($neighbor.peer_kind // "") == "external-uplink" and ($neighbor.peer_asn // null) != null and ((($neighbor.peer_addr4 // "") != "") or (($neighbor.peer_addr6 // "") != "")) then
              empty
            elif $peerIndex == null then
              violation("bgp-neighbor"; $site.name; $site.enterprise; $site.site; $router.node; "neighbor peer_name is not a modeled router: " + ($neighbor.peer_name // "<missing>"))
            elif $policy != null and $router.role == "policy" and ($neighbor.route_reflector_client // false) != true then
              violation("bgp-neighbor"; $site.name; $site.enterprise; $site.site; $router.node; "policy router neighbor is not marked route_reflector_client: " + ($neighbor.peer_name // "<missing>"))
            elif $policy != null and $router.role != "policy" and ($neighbor.peer_name // "") != $policy.node then
              violation("bgp-neighbor"; $site.name; $site.enterprise; $site.site; $router.node; "non-policy router peers with non-policy router: " + ($neighbor.peer_name // "<missing>"))
            elif $router.role != "policy" and ($neighbor.route_reflector_client // false) == true then
              violation("bgp-neighbor"; $site.name; $site.enterprise; $site.site; $router.node; "non-policy router has route_reflector_client neighbor")
            else empty end
        end
    ),
    (
      $routers[]
      | select(.role == "access")
      | . as $router
      | [
          { family: "ipv4", networks: (($router.bgp.networks.ipv4 // []) + ([$router.bgp.networks[]? | select(type == "object" and .family == "ipv4")])) },
          { family: "ipv6", networks: (($router.bgp.networks.ipv6 // []) + ([$router.bgp.networks[]? | select(type == "object" and .family == "ipv6")])) }
        ][]
      | select((.networks | length) == 0)
      | violation("bgp-access-networks"; $site.name; $site.enterprise; $site.site; $router.node; "access router has no exported " + .family + " bgp.networks")
    );

bgp_policy_rr_violations
