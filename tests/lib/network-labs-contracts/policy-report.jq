include "common";

def service_provider_endpoint_violations:
  sites as $site
  | ($site.data.services // [])[]
  | . as $service
  | ($service.providers // []) as $providers
  | ($service.providerEndpoints // []) as $endpoints
  | if ($providers | length) != ($endpoints | length) then
      violation("service-provider-endpoint"; $site.name; $site.enterprise; $site.site; ($service.name // ""); "service providers are not exactly materialized as providerEndpoints")
    else
      $endpoints[]
      | . as $endpoint
      | if (($providers | index($endpoint.name // "")) == null) then
          violation("service-provider-endpoint"; $site.name; $site.enterprise; $site.site; ($service.name // ""); "providerEndpoint name is not listed in service providers: " + ($endpoint.name // "<missing>"))
        elif (($endpoint.ipv4 // []) | length) == 0 and (($endpoint.ipv6 // []) | length) == 0 then
          violation("service-provider-endpoint"; $site.name; $site.enterprise; $site.site; ($service.name // ""); "providerEndpoint has no concrete ipv4 or ipv6 addresses: " + ($endpoint.name // "<missing>"))
        else empty end
    end;

def policy_target($site):
  ($site.data.runtimeTargets // {})
  | to_entries[]
  | select((.value.role // "") == "policy")
  | .;

def deny_materialized($rules; $relation):
  [
    $rules[]
    | select((.action // "") as $action | ["deny", "drop", "reject"] | index($action) != null)
    | select((.relationId // .relation // .id // "") == ($relation.id // ""))
  ] | length > 0;

def policy_deny_violations:
  sites as $site
  | policy_target($site) as $policy
  | ($policy.value.forwardingIntent.rules // []) as $rules
  | ($site.data.relations // [])[]
  | select((.action // "") == "deny")
  | select(deny_materialized($rules; .) | not)
  | violation("policy-deny"; $site.name; $site.enterprise; $site.site; ($policy.key // ""); "deny relation is not materialized as an explicit policy rule: " + (.id // "<missing>"));

service_provider_endpoint_violations,
policy_deny_violations
