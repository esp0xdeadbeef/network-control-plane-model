#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

expr='
let
  flake = builtins.getFlake ("path:" + toString ./.);
  lib = flake.inputs.nixpkgs.lib;
  helpers = import ./lib/contract.nix { inherit lib; };
  ipam = import ./src/cpm/ipam.nix { inherit lib; };
  common = rec {
    attrsOrEmpty = value: if builtins.isAttrs value then value else { };
    listOrEmpty = value: if builtins.isList value then value else [ ];
    uniqueStrings = values: builtins.attrNames (builtins.listToAttrs (map (value: { name = value; value = true; }) values));
  };
  routeHelpers = import ./src/cpm/ControlModule/route-helpers.nix { inherit lib helpers common ipam; };
  augment = import ./src/cpm/ControlModule/route-augmentation/service-ingress.nix {
    inherit lib helpers common ipam routeHelpers;
    sitePath = "test.site";
    attachments = [ { kind = "tenant"; name = "dmz"; unit = "c-router-access-dmz"; } ];
    nodes = { };
    allowedRelations = [
      {
        id = "allow-wan-to-dmz-nebula";
        action = "allow";
        from = { kind = "external"; uplinks = [ "wan" ]; };
        to = { kind = "service"; name = "dmz-nebula"; };
        trafficType = "nebula";
      }
    ];
    serviceDefinitions = {
      dmz-nebula = {
        providers = [ "c-router-lighthouse" ];
        trafficType = "nebula";
      };
    };
    providerEndpointForServiceProvider = _provider: {
      ipv4 = [ "10.90.10.100" ];
      ipv6 = [ "fd42:dead:cafe:10::100" ];
    };
    providerTenantsForServiceProvider = _provider: [ "dmz" ];
  };
  target = {
    role = "upstream-selector";
    effectiveRuntimeRealization.interfaces = {
      core = {
        addr4 = "10.80.0.19/31";
        addr6 = "fd42:dead:cafe:1000::13/127";
        backingRef.lane = { kind = "uplink"; uplinks = [ "wan" ]; };
        routes.ipv4 = [ ];
        routes.ipv6 = [ ];
      };
      policy-dmz-wan = {
        addr4 = "10.80.0.19/31";
        addr6 = "fd42:dead:cafe:1000::13/127";
        backingRef.lane = {
          kind = "access-uplink";
          access = "c-router-access-dmz";
          uplinks = [ "wan" ];
        };
        routes.ipv4 = [ ];
        routes.ipv6 = [ ];
      };
    };
  };
  result = augment "c-router-upstream-selector" target;
  interfaces = result.effectiveRuntimeRealization.interfaces;
  hasRoute4 = routes:
    builtins.any
      (route:
        (route.dst or null) == "10.90.10.100"
        && (route.via4 or null) == "10.80.0.18"
        && (route.intent.kind or null) == "service-ingress"
        && (route.intent.relation or null) == "allow-wan-to-dmz-nebula")
      routes;
  hasRoute6 = routes:
    builtins.any
      (route:
        (route.dst or null) == "fd42:dead:cafe:10::100"
        && (route.via6 or null) == "fd42:dead:cafe:1000::12"
        && (route.intent.kind or null) == "service-ingress")
      routes;
in
  hasRoute4 interfaces.policy-dmz-wan.routes.ipv4
  && hasRoute4 interfaces.core.routes.ipv4
  && hasRoute6 interfaces.policy-dmz-wan.routes.ipv6
  && hasRoute6 interfaces.core.routes.ipv6
'

if nix eval --extra-experimental-features 'nix-command flakes' --impure --expr "$expr" | grep -qx true; then
  echo "PASS service-ingress-provider-tenant-lane"
else
  echo "FAIL service-ingress-provider-tenant-lane" >&2
  exit 1
fi
