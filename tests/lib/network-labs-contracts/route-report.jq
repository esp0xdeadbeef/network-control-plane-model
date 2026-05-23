include "common";

def route_key($route):
  [
    $route.name,
    $route.enterprise,
    $route.site,
    $route.target,
    $route.interface,
    $route.family,
    ($route.data.dst // ""),
    ($route.data.sourceFile // ""),
    ($route.data.via4 // ""),
    ($route.data.via6 // ""),
    ($route.data.scope // ""),
    (($route.data.lane // {}).access // ""),
    (($route.data.lane // {}).uplink // ""),
    (($route.data.policyOnly // false) | tostring),
    (($route.data.intent // {}).kind // ""),
    (($route.data.intent // {}).source // "")
  ] | @json;

def route_shape_violations:
  sites as $site
  | route_records($site) as $route
  | ($route.data.intent // {}) as $intent
  | (
      $route.family == "ipv6"
      and (($route.data.sourceFile // "") != "")
      and (($intent.kind // "") == "runtime-routed-prefix-return")
      and ((($intent.source // "") == "inventory-routed-prefix") or (($intent.source // "") == "intent-routed-prefix"))
    ) as $isRuntimeRoutedPrefixReturn
  | (
      (($route.data.sourceFile // "") != "")
      and (($intent.kind // "") == "overlay-underlay-reachability")
      and (($intent.source // "") == "overlay-underlay-endpoint")
    ) as $isRuntimeUnderlayEndpoint
  | if ($route.data.dst // "") == "" and ($isRuntimeRoutedPrefixReturn | not) and ($isRuntimeUnderlayEndpoint | not) then
      violation("route-shape"; $route.name; $route.enterprise; $route.site; $route.target; "route on " + $route.interface + " " + $route.family + " is missing dst")
    elif ($intent | type) != "object" or (($intent.kind // $intent.source // "") == "") then
      violation("route-shape"; $route.name; $route.enterprise; $route.site; $route.target; "route " + ($route.data.dst // "<missing>") + " on " + $route.interface + " lacks intent kind/source")
    elif $route.family == "ipv4" and (($route.data.via6 // "") != "") then
      violation("route-shape"; $route.name; $route.enterprise; $route.site; $route.target; "ipv4 route " + ($route.data.dst // "<missing>") + " carries via6")
    elif $route.family == "ipv6" and (($route.data.via4 // "") != "") then
      violation("route-shape"; $route.name; $route.enterprise; $route.site; $route.target; "ipv6 route " + ($route.data.dst // "<missing>") + " carries via4")
    else
      empty
    end;

def duplicate_route_violations:
  sites as $site
  | [route_records($site)] as $routes
  | ($routes | group_by(route_key(.))[] | select(length > 1) | .[0]) as $route
  | violation("route-duplicate"; $route.name; $route.enterprise; $route.site; $route.target; "duplicate route on " + $route.interface + " " + $route.family + " for " + ($route.data.dst // "<missing>"));

def overlay_interface_transit_endpoint_violations:
  sites as $site
  | overlay_names($site) as $overlays
  | route_records($site)
  | . as $route
  | select(($overlays | index($route.interface)) != null or (($route.interface | startswith("overlay-")) and (($overlays | index($route.interface | sub("^overlay-"; ""))) != null)))
  | select((($route.data.intent // {}).source // "") == "transit-endpoint")
  | violation("overlay-transit-endpoint"; $route.name; $route.enterprise; $route.site; $route.target; "overlay interface " + $route.interface + " carries transit-endpoint route " + ($route.data.dst // "<missing>"));

def default_route_lane_violations:
  sites as $site
  | overlay_names($site) as $overlays
  | delegated_access_nodes($site) as $delegated
  | runtime_targets($site) as $target
  | $delegated[] as $access
  | [
      ($target.data.effectiveRuntimeRealization.interfaces // {})
      | to_entries[]
      | (.value.routes.ipv6 // [])[]
      | select((.dst // "") == "::/0" or (.dst // "") == "0000:0000:0000:0000:0000:0000:0000:0000/0")
      | select(((.lane // {}).access // "") == $access)
    ] as $defaults
  | select(($defaults | length) > 0)
  | if (($overlays | length) > 0 and ([$defaults[] as $route | select(($overlays | index((($route.lane // {}).uplink // ""))) != null)] | length) == 0) then
      violation("default-route-lane"; $target.name; $target.enterprise; $target.site; $target.id; "delegated IPv6 access " + $access + " has defaults but no overlay default lane")
    else
      empty
    end;

route_shape_violations,
duplicate_route_violations,
overlay_interface_transit_endpoint_violations,
default_route_lane_violations
