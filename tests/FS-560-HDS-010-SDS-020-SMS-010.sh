#!/usr/bin/env bash
# GAMP-ID: FS-560-HDS-010-SDS-020-SMS-010
# GAMP-SCOPE: software-module-test
set -euo pipefail

repo_root="${SMS_TEST_REPO_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)}"

REPO_ROOT="${repo_root}" nix eval --impure --raw --expr '
  let
    repoRoot = builtins.getEnv "REPO_ROOT";
    flake = builtins.getFlake ("path:" + repoRoot);
    lib = flake.inputs.nixpkgs.lib;
    common = {
      attrsOrEmpty = value: if builtins.isAttrs value then value else { };
      failForwarding = path: message: throw "${path}: ${message}";
      uniqueStrings = values: lib.sort builtins.lessThan (lib.unique values);
      ipam.canonicalNetworkPrefix = value: value;
    };
    apply = import (repoRoot + "/src/cpm/ControlModule/runtime-targets/local-dns-sharing.nix") {
      inherit lib common;
      enterpriseName = "test";
      siteName = "site";
      sitePath = "test.site";
      siteDns = { };
      serviceDefinitions = {
        requester = { providers = [ "requester-node" ]; };
        authority = { providers = [ "authority-node" ]; };
      };
      allowedRelations = [{
        id = "requester-to-authority";
        action = "allow";
        trafficType = "dns";
        from = { kind = "service"; name = "requester"; };
        to = { kind = "service"; name = "authority"; };
      }];
      inventoryEndpoints = { };
    };
    targets = {
      requester-target = {
        logicalNode.name = "requester-node";
        services.dns = { listen = [ "192.0.2.10" ]; };
      };
      authority-target = {
        logicalNode.name = "authority-node";
        services.dns = {
          listen = [ "192.0.2.20" ];
          localRecords = [{ name = "host.example."; a = [ "192.0.2.30" ]; }];
        };
      };
    };
    result = apply targets;
    warnings = result.requester-target.services.dns.reproducibilityWarnings;
    warning = builtins.head warnings;
    require = condition: message: if condition then true else throw message;
  in
  if
    require (builtins.length warnings == 1) "missing local-sharing intent did not warn"
    && require (warning.traceId == "FS-560-HDS-010-SDS-020-SMS-010") "warning lost trace"
    && require (warning.code == "DNS_LOCAL_SHARING_INTENT_MISSING") "warning lost code"
    && require (warning.sourceLayer == "intent") "warning lost source ownership"
    && require (warning.relationId == "requester-to-authority") "warning lost relation ownership"
  then "ok" else throw "unreachable"
' >/dev/null

echo "PASS FS-560-HDS-010-SDS-020-SMS-010 CPM missing directional local-sharing warning"
