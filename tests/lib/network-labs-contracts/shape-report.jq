include "common";

def root_shape_violations:
  select((.name // "") == "" or (.output.control_plane_model.data // null) == null)
  | violation("root-shape"; (.name // "<missing>"); ""; ""; ""; "compiled output must contain named control_plane_model.data");

def runtime_identity_violations:
  sites as $site
  | runtime_targets($site)
  | select(((.data.role // "") == "") or ((.data.logicalNode.enterprise // "") == "") or ((.data.logicalNode.site // "") == "") or ((.data.logicalNode.name // "") == ""))
  | violation("runtime-identity"; .name; .enterprise; .site; .id; "runtime target is missing role or logicalNode identity");

def forwarding_rule_interface_violations:
  sites as $site
  | runtime_targets($site) as $target
  | interface_names($target) as $interfaces
  | ($target.data.forwardingIntent.rules // [])
  | to_entries[]
  | . as $rule
  | select(($rule.value.action // "") == "accept")
  | select(($interfaces | index($rule.value.fromInterface // "")) == null or ($interfaces | index($rule.value.toInterface // "")) == null)
  | violation(
      "forwarding-rule-interface";
      $target.name;
      $target.enterprise;
      $target.site;
      $target.id;
      ("accept rule " + ($rule.key | tostring) + " references unrealized interface " + ($rule.value.fromInterface // "<missing>") + " -> " + ($rule.value.toInterface // "<missing>"))
    );

def transit_ordering_violations:
  sites as $site
  | ($site.data.transit.ordering // []) as $ordering
  | ([($site.data.transit.adjacencies // [])[] | .id] | sort) as $adjacencyIds
  | ($ordering | sort) as $orderingIds
  | select(($orderingIds | length) != ($adjacencyIds | length) or $orderingIds != $adjacencyIds)
  | violation("transit-ordering"; $site.name; $site.enterprise; $site.site; ""; "ordering does not exactly match adjacency IDs");

def communication_contract_violations:
  sites as $site
  | sorted_strings([($site.data.relations // [])[] | .id // empty]) as $relations
  | sorted_strings([(($site.data.communicationContract.relations // []) + ($site.data.communicationContract.allowedRelations // []))[] | .id // empty]) as $contractRelations
  | select(($relations | length) != ($contractRelations | length) or $relations != $contractRelations)
  | violation("communication-contract"; $site.name; $site.enterprise; $site.site; ""; "site relations are not exactly materialized in communicationContract");

def relation_service_violations:
  sites as $site
  | sorted_strings([($site.data.services // [])[] | .name // empty]) as $services
  | ($site.data.relations // [])[]
  | . as $relation
  | [$relation.from, $relation.to][]
  | select(type == "object" and (.kind // "") == "service")
  | select(($services | index(.name // "")) == null)
  | violation("relation-service"; $site.name; $site.enterprise; $site.site; ($relation.id // ""); "relation references service not compiled in site.services: " + (.name // "<missing>"));

root_shape_violations,
runtime_identity_violations,
forwarding_rule_interface_violations,
transit_ordering_violations,
communication_contract_violations,
relation_service_violations
