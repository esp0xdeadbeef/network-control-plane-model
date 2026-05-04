{ }:

let
  uniqueStrings =
    list:
    builtins.attrNames (
      builtins.listToAttrs (map (value: { name = value; value = true; }) list)
    );
in
{
  endpointKey =
    endpoint:
    if endpoint == "any" then
      "any"
    else if builtins.isString endpoint then
      "string:${endpoint}"
    else if builtins.isAttrs endpoint then
      let
        kind = endpoint.kind or null;
      in
      if kind == "tenant" then
        "tenant:${endpoint.name or ""}"
      else if kind == "tenant-set" then
        "tenant-set:${builtins.concatStringsSep "," (uniqueStrings (endpoint.members or [ ]))}"
      else if kind == "external" then
        "external:${
          if builtins.isString (endpoint.name or null) then
            endpoint.name
          else
            builtins.concatStringsSep "," (uniqueStrings (endpoint.uplinks or [ ]))
        }"
      else if kind == "service" then
        "service:${endpoint.name or ""}"
      else
        builtins.toJSON endpoint
    else
      builtins.toJSON endpoint;
}
