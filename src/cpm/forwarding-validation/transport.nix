{ common }:

let inherit (common) failForwarding;
in
{
  validate = sitePath: siteAttrs:
    let transport = siteAttrs.transport or null;
    in
    if transport == null then
      true
    else if !builtins.isAttrs transport then
      failForwarding "${sitePath}.transport" "site.transport must be an attribute set"
    else
      let overlays = transport.overlays or null;
      in
      if overlays == null || builtins.isAttrs overlays || builtins.isList overlays then
        true
      else
        failForwarding "${sitePath}.transport.overlays" "site.transport.overlays must be an attribute set or list";
}
