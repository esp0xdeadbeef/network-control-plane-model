def documents:
  select(
    type == "object"
    and (.name // "") != ""
    and (.output | type) == "object"
    and (.output.control_plane_model.data // null) != null
  );

def sites:
  documents
  | . as $doc
  | $doc.output.control_plane_model.data
  | to_entries[] as $enterprise
  | $enterprise.value
  | to_entries[]
  | {
      name: $doc.name,
      enterprise: $enterprise.key,
      site: .key,
      data: .value
    };

def runtime_targets($site):
  $site.data.runtimeTargets // {}
  | to_entries[]
  | {
      name: $site.name,
      enterprise: $site.enterprise,
      site: $site.site,
      id: .key,
      data: .value
    };

def interface_names($target):
  [
    ($target.data.effectiveRuntimeRealization.interfaces // {})
    | to_entries[]
    | (.value.runtimeIfName // .value.renderedIfName // .key)
  ];

def router_roles:
  {
    "access": true,
    "core": true,
    "downstream-selector": true,
    "policy": true,
    "upstream-selector": true
  };

def router_targets($site):
  [
    runtime_targets($site)
    | select((router_roles[.data.role // ""] // false) == true)
    | {
        id: .id,
        node: (.data.logicalNode.name // ""),
        role: (.data.role // ""),
        bgp: (.data.bgp // null)
      }
  ];

def overlay_names($site):
  (($site.data.overlays // {}) | keys);

def sorted_strings($items):
  [$items[] | select(type == "string")] | sort;

def violation($kind; $name; $enterprise; $site; $target; $detail):
  [$kind, $name, $enterprise, $site, $target, $detail] | @tsv;

def route_records($site):
  runtime_targets($site) as $target
  | ($target.data.effectiveRuntimeRealization.interfaces // {})
  | to_entries[] as $interface
  | ["ipv4", "ipv6"][] as $family
  | ($interface.value.routes[$family] // [])
  | to_entries[]
  | {
      name: $target.name,
      enterprise: $target.enterprise,
      site: $target.site,
      target: $target.id,
      interface: $interface.key,
      runtimeIfName: ($interface.value.runtimeIfName // $interface.value.renderedIfName // $interface.key),
      family: $family,
      index: .key,
      data: .value
    };

def delegated_access_nodes($site):
  [
    runtime_targets($site)
    | select((.data.role // "") == "access")
    | select(
        ((.data.externalValidation.delegatedIPv6Prefix // false) == true)
        or ((.data.externalValidation.delegatedPrefixSecretName // "") != "")
        or ((.data.advertisements.externalValidation.delegatedIPv6Prefix // false) == true)
        or ((.data.advertisements.externalValidation.delegatedPrefixSecretName // "") != "")
      )
    | .data.logicalNode.name
  ];

def public_resolvers:
  [
    "1.1.1.1",
    "1.0.0.1",
    "8.8.8.8",
    "8.8.4.4",
    "9.9.9.9",
    "2606:4700:4700::1111",
    "2606:4700:4700::1001",
    "2001:4860:4860::8888",
    "2001:4860:4860::8844",
    "2620:fe::fe"
  ];

def expected_dns_route_preference:
  [
    "local-access",
    "overlay-core",
    "service-dns",
    "explicit-egress-default"
  ];
