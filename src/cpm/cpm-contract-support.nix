{ lib }:

let
  contract = import ../../lib/contract.nix { inherit lib; };

  requireRoutes = path: value:
    let
      routes = contract.requireAttrs "${path}.routes" value;
      ipv4 = routes.ipv4 or [ ];
      ipv6 = routes.ipv6 or [ ];
    in
    if !builtins.isList ipv4 then
      throw "runtime realization failure: ${path}.routes.ipv4 must be a list"
    else if !builtins.isList ipv6 then
      throw "runtime realization failure: ${path}.routes.ipv6 must be a list"
    else
      {
        inherit ipv4 ipv6;
      };

  logicalKey = logical:
    "${logical.enterprise}|${logical.site}|${logical.name}";
in
contract // {
  inherit
    logicalKey
    requireRoutes;
}
