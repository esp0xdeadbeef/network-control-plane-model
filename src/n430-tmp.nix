let
  flake = builtins.getFlake "/home/deadbeef/github/network-control-plane-model";
  system = builtins.currentSystem;
  lib = flake.inputs.nixpkgs.lib;
  helpers = import ./src/cpm/cpm-contract-support.nix { inherit lib; };
  ipam = import ./src/cpm/ipam.nix { inherit lib; };
  buildNat = import ./src/cpm/firewall-intent/nat.nix { inherit helpers lib ipam; };
  siteAttrs = { domains.tenants = [ { name = "tenant-a"; ipv6 = "fd42:dead:beef:10::/64"; } ]; };
  baseWan = {
    sourceKind = "wan"; upstream = "wan"; sourceInterfaceName = "wan0"; runtimeIfName = "eth0";
    hostUplink = { ipv4 = { method = "dhcp"; }; ipv6 = { method = "slaac"; }; };
    wan.egress.ipv6.translation = { mode = "nat66"; translatedPrefix = "2001:db8:430::/64"; };
  };
  target = { role = "core"; egressIntent = { exit = true; trafficClass = "tenant-internet"; uplinks = [ "wan" ]; wanInterfaces = [ "wan" ]; nat66.wan = { mode = "nat66"; sourcePrefixes = [ "fd42:dead:beef:10::/64" ]; }; }; };
  r = buildNat { inherit siteAttrs target; runtimeOriginSourcePrefixes = [ ]; overlayNames = [ ]; interfaceRecords = [ baseWan ]; };
in builtins.head r.diagnostics.nat66
