{
  repoRoot,
  nixpkgsPath,
  caseName ? "valid",
}:

let
  lib = import (nixpkgsPath + "/lib");
  helpers = import (repoRoot + "/src/cpm/cpm-contract-support.nix") { inherit lib; };
  attrsOrEmpty = value: if builtins.isAttrs value then value else { };
  failInventory = path: message: throw "inventory contract violation at ${path}: ${message}";
  noStrings = _: [ ];
  noDirectEgress = _: false;
  runtimeServices = import (repoRoot + "/src/cpm/Unit/runtime-services/default.nix") {
    inherit lib helpers attrsOrEmpty failInventory;
    sitePath = "enterprise.test.site.test";
    attachments = [ ];
    policyDerivedDnsAllowFromForListeners = noStrings;
    policyDerivedDnsAllowedClassesForListeners = noStrings;
    policyDerivedDnsAllowedClassesForTenants = noStrings;
    policyDerivedDnsDirectEgressBlockedTenants = noStrings;
    policyDerivedDnsDirectEgressBlockedForListeners = noDirectEgress;
    policyDerivedDnsDirectEgressBlockedForTenants = noDirectEgress;
    policyDerivedDnsForwardersForListeners = noStrings;
    policyDerivedDnsForwardersForTenants = noStrings;
    policyDerivedDnsUpstreamRecordsForListeners = noStrings;
    uniqueStrings = values: lib.unique values;
  };
  ipv6 = {
    mode = "dhcpv6-pd";
    defaultRoute = true;
    iaid = 7;
    prefixDelegationRequestId = 11;
    duidMode = "persistent";
    resolverMode = "disabled";
    ipv4Mode = "disabled";
    routerSolicitation = false;
    fallbackPolicy = "none";
  };
  baseClient = {
    interface = "provider-handoff";
    runtimeInterface = "ppp-test";
    defaultRoute = true;
    usePeerDns = false;
    mtu = 1492;
    credentials = {
      usernameFile = "/run/secrets/test-username";
      passwordFile = "/run/secrets/test-password";
    };
    inherit ipv6;
  };
  selectedClient =
    if caseName == "valid" then
      baseClient
    else if caseName == "missing-interface" then
      builtins.removeAttrs baseClient [ "interface" ]
    else if caseName == "missing-runtime-interface" then
      builtins.removeAttrs baseClient [ "runtimeInterface" ]
    else if caseName == "missing-mtu" then
      builtins.removeAttrs baseClient [ "mtu" ]
    else if caseName == "missing-iaid" then
      baseClient // { ipv6 = builtins.removeAttrs ipv6 [ "iaid" ]; }
    else if caseName == "missing-pd-request-id" then
      baseClient // { ipv6 = builtins.removeAttrs ipv6 [ "prefixDelegationRequestId" ]; }
    else if caseName == "missing-ipv6-default-route" then
      baseClient // { ipv6 = builtins.removeAttrs ipv6 [ "defaultRoute" ]; }
    else if caseName == "ipv4-enabled" then
      baseClient // { ipv6 = ipv6 // { ipv4Mode = "enabled"; }; }
    else if caseName == "router-solicitation" then
      baseClient // { ipv6 = ipv6 // { routerSolicitation = true; }; }
    else if caseName == "fallback-enabled" then
      baseClient // { ipv6 = ipv6 // { fallbackPolicy = "slaac"; }; }
    else if caseName == "resolver-enabled" then
      baseClient // { ipv6 = ipv6 // { resolverMode = "enabled"; }; }
    else if caseName == "invented-field" then
      baseClient // { ipv6 = ipv6 // { inventedPppInterface = "ppp0"; }; }
    else if caseName == "changed-iaid" then
      baseClient // { ipv6 = ipv6 // { iaid = "7"; }; }
    else if caseName == "changed-pd-request-id" then
      baseClient // { ipv6 = ipv6 // { prefixDelegationRequestId = "11"; }; }
    else
      throw "unknown FS-800 test case";
  normalized = runtimeServices.resolveRuntimeServices {
    nodePath = "enterprise.test.site.test.nodes.core";
    nodeName = "core";
    nodeAttrs = {
      role = "core";
      services = { };
    };
    targetDef = {
      nodePath = "realization.nodes.core";
      node = {
        services.pppoe.client = selectedClient;
      };
    };
    loopback = { };
  };
in
builtins.deepSeq normalized normalized.pppoe.client
