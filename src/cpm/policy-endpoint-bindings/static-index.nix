{ helpers, bindingCommon }:

{ sitePath, attachments, domains }:

let
  inherit (helpers) requireAttrs requireString;
  inherit (bindingCommon) appendListValue;
in
{
  attachmentsByTenant =
    builtins.foldl'
      (acc: attachment:
        let
          attachmentAttrs = requireAttrs "${sitePath}.attachments[*]" attachment;
          kind = requireString "${sitePath}.attachments[*].kind" (attachmentAttrs.kind or null);
          name = requireString "${sitePath}.attachments[*].name" (attachmentAttrs.name or null);
          unit = requireString "${sitePath}.attachments[*].unit" (attachmentAttrs.unit or null);
          attachmentId = "attachment::${unit}::${kind}::${name}";
        in
        if kind != "tenant" then acc else appendListValue acc name { inherit attachmentId kind name unit; })
      { }
      attachments;

  domainsByTenant =
    builtins.foldl'
      (acc: tenant:
        let
          tenantAttrs = requireAttrs "${sitePath}.domains.tenants[*]" tenant;
          tenantName = requireString "${sitePath}.domains.tenants[*].name" (tenantAttrs.name or null);
        in
        appendListValue acc tenantName tenantAttrs)
      { }
      domains.tenants;
}
