{ lib
, inventory ? { }
}:

let
  deploymentHosts =
    if inventory ? deployment && inventory.deployment ? hosts then
      inventory.deployment.hosts
    else
      { };
  testClientsHost = deploymentHosts."s-router-test-clients" or { };
  testClientHat = testClientsHost.hat or { };
  testClientEndpointClients = testClientHat.endpointClients or { };
  requiredTestClientEndpointNames = testClientHat.requiredEndpointClients or [ ];

  missingRequiredTestClientEndpoints =
    builtins.filter
      (name: !(builtins.hasAttr name testClientEndpointClients))
      requiredTestClientEndpointNames;

  firstAddress = endpointName: endpoint: family:
    let values = endpoint.${family} or [ ];
    in
    if values == [ ] then
      throw "FS-720-HDS-030-SDS-010-SMS-010: static endpoint ${endpointName} has no ${family} address"
    else
      builtins.head values;

  stripCidr = cidr: builtins.head (lib.splitString "/" cidr);
  prefixLength = cidr:
    let parts = lib.splitString "/" cidr;
    in
    if builtins.length parts >= 2 then
      lib.toInt (builtins.elemAt parts 1)
    else
      throw "FS-720-HDS-030-SDS-010-SMS-010: static endpoint address ${cidr} has no prefix length";

  requireEndpointField = endpointName: endpoint: field:
    if builtins.hasAttr field endpoint then
      endpoint.${field}
    else
      throw "FS-720-HDS-030-SDS-010-SMS-010: static endpoint ${endpointName} has no ${field}";

  endpointMode = endpointName: endpoint:
    let assignment = endpoint.assignment or null;
    in
    if assignment == "dhcp" || assignment == "dhcpv6" then
      "dhcp"
    else if assignment == "static" || assignment == "static-only" || assignment == "static-ipv4-or-ipv6-client" then
      "static"
    else
      throw "FS-720-HDS-030-SDS-010-SMS-010: endpoint ${endpointName} has unsupported assignment ${if assignment == null then "missing" else toString assignment}";

  endpointFamily = endpoint:
    let
      hasV4 = (endpoint.ipv4 or [ ]) != [ ];
      hasV6 = (endpoint.ipv6 or [ ]) != [ ];
    in
    if hasV4 && hasV6 then "dual"
    else if hasV4 then "ipv4"
    else if hasV6 then "ipv6"
    else "none";
in
if testClientEndpointClients == { } then
  { }
else if missingRequiredTestClientEndpoints != [ ] then
  throw "FS-720-HDS-010-SDS-020-SMS-020: missing required endpoint fixtures: ${builtins.concatStringsSep "," missingRequiredTestClientEndpoints}"
else
  builtins.mapAttrs
    (name: endpoint:
      let
        mode = endpointMode name endpoint;
        family = endpointFamily endpoint;
        bridge = requireEndpointField name endpoint "bridge";
      in
      {
        inherit name mode family bridge;
        tenant = requireEndpointField name endpoint "tenant";
        owningSubstrate = endpoint.owningSubstrate or "s-router-test-clients";
        namespaceOwner = endpoint.namespaceOwner or "s-router-test-clients";
        sourcePath = "deployment.hosts.s-router-test-clients.hat.endpointClients.${name}";
        gampIds = [
          "FS-720-HDS-010-SDS-020-SMS-020"
          "FS-720-HDS-030-SDS-010-SMS-010"
        ];
      }
      // (if mode == "static" then {
        static = {
          address = stripCidr (firstAddress name endpoint "ipv4");
          prefixLength = prefixLength (firstAddress name endpoint "ipv4");
          gateway4 = requireEndpointField name endpoint "gateway4";
          address6 = stripCidr (firstAddress name endpoint "ipv6");
          prefixLength6 = prefixLength (firstAddress name endpoint "ipv6");
          gateway6 = requireEndpointField name endpoint "gateway6";
        };
      } else { }))
    testClientEndpointClients
