{
  lib,
  helpers,
  common,
  sitePath,
  attachments,
  nodes,
  serviceDefinitions,
  providerTenantsForServiceProvider,
}:

let
  inherit (helpers) isNonEmptyString requireString sortedNames;
  inherit (common) attrsOrEmpty listOrEmpty uniqueStrings;

  providerTenantsForService =
    serviceName:
    uniqueStrings (
      lib.concatMap providerTenantsForServiceProvider
        (listOrEmpty ((serviceDefinitions.${serviceName} or { }).providers or null))
    );

  accessNodesForTenant =
    tenantName:
    let
      globalAttachments =
        lib.concatMap
          (attachment:
            let attachmentAttrs = attrsOrEmpty attachment;
            in
            if
              (attachmentAttrs.kind or null) == "tenant"
              && (attachmentAttrs.name or null) == tenantName
              && isNonEmptyString (attachmentAttrs.unit or null)
            then
              [ (requireString "${sitePath}.attachments[*].unit" attachmentAttrs.unit) ]
            else
              [ ])
          attachments;
      nodeAttachments =
        lib.concatMap
          (nodeName:
            let
              nodeAttrs = attrsOrEmpty nodes.${nodeName};
              attachedTenants =
                lib.concatMap
                  (attachment:
                    let attachmentAttrs = attrsOrEmpty attachment;
                    in
                    if (attachmentAttrs.kind or null) == "tenant" && (attachmentAttrs.name or null) == tenantName then
                      [ tenantName ]
                    else
                      [ ])
                  (listOrEmpty (nodeAttrs.attachments or null));
            in
            if attachedTenants != [ ] then [ nodeName ] else [ ])
          (sortedNames nodes);
    in
    uniqueStrings (globalAttachments ++ nodeAttachments);

  providerAccessNodesForService =
    serviceName:
    uniqueStrings (lib.concatMap accessNodesForTenant (providerTenantsForService serviceName));
in
{
  inherit providerAccessNodesForService;
}
