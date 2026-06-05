{ helpers, bindingCommon }:

{ sitePath
, policyInterfaceTags
, siteUplinkNames
, declaredExternalNames
, serviceDefinitions
, attachmentsByTenant
, domainsByTenant
, runtimeTenantBindingsByTenant
, runtimeExternalBindingsByName
, relationTenantNames
, relationExternalNames
, serviceNamesFromContract
, relationTenantSet
, relationExternalSet
, relationRequiredTenantSet ? relationTenantSet
, relationRequiredExternalSet ? relationExternalSet
, relations
,
}:

let
  inherit (helpers) hasAttr sortedNames;
  inherit (bindingCommon) failForwarding listOrEmpty uniqueStrings;

  relationId = relation:
    if builtins.isString (relation.id or null) && relation.id != "" then
      relation.id
    else if builtins.isString (relation.name or null) && relation.name != "" then
      relation.name
    else
      null;

  namesForEndpoint = endpointRaw:
    let
      endpoint = if builtins.isAttrs endpointRaw then endpointRaw else { };
      kind = endpoint.kind or null;
    in
    if kind == "tenant" then
      builtins.filter (value: builtins.isString value && value != "") [ endpoint.name or null ]
    else if kind == "tenant-set" then
      builtins.filter (value: builtins.isString value && value != "") (listOrEmpty (endpoint.members or null))
    else if kind == "external" then
      if builtins.isString (endpoint.name or null) && endpoint.name != "" then
        [ endpoint.name ]
      else
        builtins.filter (value: builtins.isString value && value != "") (listOrEmpty (endpoint.uplinks or null))
    else
      [ ];

  unresolvedDenyDiagnostics =
    builtins.concatLists (
      builtins.genList
        (idx:
          let
            relation = if builtins.isAttrs (builtins.elemAt relations idx) then builtins.elemAt relations idx else { };
            isDeny = (relation.action or "allow") == "deny";
            relationMeta = {
              code = "unresolved-modeled-deny-endpoint";
              mode = "fail-closed";
              failClosed = true;
              fallback = "no-renderer-inference";
              action = "deny";
              relationId = relationId relation;
              priority = relation.priority or null;
              trafficType = relation.trafficType or "any";
              from = if builtins.isAttrs (relation.from or null) then relation.from else relation.from or null;
              to = if builtins.isAttrs (relation.to or null) then relation.to else relation.to or null;
              message = "Modeled deny endpoint did not resolve to a concrete policy surface; CPM preserves the deny as a fail-closed diagnostic instead of emitting an implicit broad deny or requiring renderer inference.";
            };
            endpointDiagnostics = side: endpointRaw:
              let
                endpoint = if builtins.isAttrs endpointRaw then endpointRaw else { };
                kind = endpoint.kind or null;
                unresolved = name:
                  {
                    inherit side kind name;
                    reason =
                      if kind == "external" then
                        "missing explicit realized external or WAN policy binding"
                      else
                        "missing explicit runtime tenant policy binding";
                    resolved = false;
                    sourceSurface = [ ];
                    destinationSurface = [ ];
                  } // relationMeta;
                missingName = name:
                  if kind == "tenant" || kind == "tenant-set" then
                    !(hasAttr name tenantBindings) || (tenantBindings.${name}.runtimeBindings or [ ]) == [ ]
                  else if kind == "external" then
                    !(hasAttr name externalBindings) || (externalBindings.${name}.runtimeBindings or [ ]) == [ ]
                  else
                    false;
              in
              if !(kind == "tenant" || kind == "tenant-set" || kind == "external") then
                [ ]
              else
                map unresolved (builtins.filter missingName (namesForEndpoint endpoint));
          in
          if !isDeny then
            [ ]
          else
            endpointDiagnostics "from" (relation.from or null)
            ++ endpointDiagnostics "to" (relation.to or null))
        (builtins.length relations)
    );

  tenantNames =
    uniqueStrings ((sortedNames attachmentsByTenant) ++ (sortedNames domainsByTenant) ++ relationTenantNames);

  externalNames =
    uniqueStrings (siteUplinkNames ++ declaredExternalNames ++ relationExternalNames ++ (sortedNames runtimeExternalBindingsByName));

  tenantBindings =
    builtins.listToAttrs (
      map
        (tenantName:
          let
            runtimeBindingList = runtimeTenantBindingsByTenant.${tenantName} or [ ];
            required =
              if hasAttr tenantName relationRequiredTenantSet && runtimeBindingList == [ ] then
                failForwarding "${sitePath}.policy.interfaceTags" "canonical policy endpoint binding for tenant '${tenantName}' requires an explicit runtime tenant interface binding"
              else
                true;
          in
          builtins.seq required {
            name = tenantName;
            value = {
              attachments = attachmentsByTenant.${tenantName} or [ ];
              domains = domainsByTenant.${tenantName} or [ ];
              runtimeBindings = runtimeBindingList;
            };
          })
        tenantNames
    );

  externalBindings =
    builtins.listToAttrs (
      map
        (externalName:
          let
            runtimeBindingList = runtimeExternalBindingsByName.${externalName} or [ ];
            hasRuntimeWANBinding = builtins.any (binding: (binding.sourceKind or null) == "wan") runtimeBindingList;
            hasRuntimeOverlayBinding = builtins.any (binding: (binding.sourceKind or null) == "overlay") runtimeBindingList;
            isDeclaredUplink = builtins.elem externalName siteUplinkNames;
            required =
              if hasAttr externalName relationRequiredExternalSet && runtimeBindingList == [ ] then
                if isDeclaredUplink then
                  failForwarding "${sitePath}.uplinkNames" "canonical policy endpoint binding for uplink '${externalName}' requires an explicit realized WAN binding"
                else
                  failForwarding "${sitePath}.nodes" "canonical policy endpoint binding for external '${externalName}' requires an explicit realized overlay or WAN binding"
              else
                true;
          in
          builtins.seq required {
            name = externalName;
            value = {
              uplinks = if isDeclaredUplink || hasRuntimeWANBinding then [ externalName ] else [ ];
              overlays = if hasRuntimeOverlayBinding then [ externalName ] else [ ];
              runtimeBindings = runtimeBindingList;
            };
          })
        externalNames
    );

  serviceBindings =
    builtins.listToAttrs (
      map
        (serviceName:
          let service = serviceDefinitions.${serviceName} or { name = serviceName; };
          in {
            name = serviceName;
            value = {
              providers = listOrEmpty (service.providers or null);
              trafficType = service.trafficType or null;
            };
          })
        serviceNamesFromContract
    );

in
{
  interfaceTags = policyInterfaceTags;
  tenants = tenantBindings;
  externals = externalBindings;
  services = serviceBindings;
  inherit relations;
} // (
  if unresolvedDenyDiagnostics == [ ] then
    { }
  else
    {
      diagnostics = {
        unresolvedDenyEndpoints = unresolvedDenyDiagnostics;
      };
    }
)
