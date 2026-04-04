{ lib }:

let
  contract = import ../../lib/contract.nix { inherit lib; };

  requireRoutes = path: value:
    let
      routes = contract.requireAttrs "${path}.routes" value;
      ipv4 = contract.requireList "${path}.routes.ipv4" (routes.ipv4 or null);
      ipv6 = contract.requireList "${path}.routes.ipv6" (routes.ipv6 or null);
    in
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
