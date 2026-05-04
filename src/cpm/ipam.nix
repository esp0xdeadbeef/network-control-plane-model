{ lib }:

let
  common = import ./ControlModule/lib/ipam/common.nix { inherit lib; };
  ipv4 = import ./ControlModule/lib/ipam/ipv4.nix { inherit common; };
  ipv6 = import ./ControlModule/lib/ipam/ipv6.nix { inherit lib common; };
  allocation = import ./ControlModule/lib/ipam/allocation.nix {
    inherit common ipv4 ipv6;
  };
in
{
  inherit (common) splitCIDR;
  inherit (ipv4)
    ipv4NetworkBaseInt
    ipv4ToInt
    parseIPv4
    renderIPv4
    ;
  inherit (ipv6)
    ipv6NetworkBaseInt
    ipv6ToInt
    parseIPv6
    renderIPv6
    ;
  inherit (allocation) allocOne;
}
