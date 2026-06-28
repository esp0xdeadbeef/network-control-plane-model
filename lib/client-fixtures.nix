# FS-720-HDS-030-SDS-010-SMS-010: CPM endpointAssignment fixture records.
# The container-local eth0 names below are NixOS private-network endpoint
# interfaces, not host bridge defaults or renderer-side topology inference.
{ lib }:

let
  stripCidr = cidr: builtins.elemAt (lib.splitString "/" cidr) 0;

  firstOrNull = values:
    if values == [ ] then null else builtins.head values;

  endpointAddress =
    inventory: endpointName: family:
    firstOrNull ((inventory.endpoints.${endpointName}.${family}) or [ ]);

  fixtureName =
    siteName: endpointName:
    if lib.hasPrefix "${siteName}-" endpointName then
      endpointName
    else
      "${siteName}-${endpointName}";

  mkDhcpClient =
    { name
    , bridge
    , dnsServers ? [ ]
    ,
    }:
    {
      autoStart = true;
      privateNetwork = true;
      hostBridge = bridge;
      config = { ... }: {
        networking.hostName = name;
        networking.useNetworkd = true;
        systemd.network.enable = true;
        networking.useDHCP = false;
        networking.useHostResolvConf = false;
        services.resolved.enable = true;

        systemd.network.networks."10-eth0" = {
          matchConfig.Name = "eth0";
          networkConfig = {
            DHCP = "ipv4";
            IPv6AcceptRA = true;
            DNS = dnsServers;
            Domains = [ "lan." ];
          };
        };

        system.stateVersion = "25.11";
      };
    };

  mkStaticClient =
    { name
    , bridge
    , addr4
    , addr6
    , gw4
    , gw6
    ,
    }:
    {
      autoStart = true;
      privateNetwork = true;
      hostBridge = bridge;
      config = { ... }: {
        networking.hostName = name;
        networking.useNetworkd = true;
        systemd.network.enable = true;
        networking.useDHCP = false;
        networking.useHostResolvConf = false;
        services.resolved.enable = true;

        systemd.network.networks."10-eth0" = {
          matchConfig.Name = "eth0";
          networkConfig = {
            Address = [
              addr4
              addr6
            ];
            DNS = [
              gw4
              gw6
            ];
            Domains = [ "lan." ];
            IPv6AcceptRA = false;
          };
          routes = [
            {
              Destination = "0.0.0.0/0";
              Gateway = gw4;
            }
            {
              Destination = "::/0";
              Gateway = gw6;
            }
          ];
        };

        system.stateVersion = "25.11";
      };
    };

  tenantPrefixes =
    site:
    builtins.listToAttrs (
      map
        (prefix: {
          name = prefix.name;
          value = prefix;
        })
        (builtins.filter (prefix: (prefix.kind or null) == "tenant") (site.ownership.prefixes or [ ]))
    );

  tenantPrefixFor =
    site: tenant:
    let
      prefixes = tenantPrefixes site;
    in
    prefixes.${tenant} or null;

  accessNodes =
    inventory: siteName:
    lib.filterAttrs
      (
        _: node:
          (node.logicalNode.site or null) == siteName
          && lib.hasPrefix "${siteName}-router-access-" (node.logicalNode.name or "")
      )
      inventory.realization.nodes;

  tenantPortNames =
    node:
    builtins.filter
      (name: lib.hasPrefix "tenant-" name)
      (builtins.attrNames (node.ports or { }));

  accessTenants =
    inventory: siteName:
    lib.unique (
      map
        (portName: lib.removePrefix "tenant-" portName)
        (lib.concatMap tenantPortNames (builtins.attrValues (accessNodes inventory siteName)))
    );

  accessNodeEntryForTenant =
    inventory: siteName: tenant:
    let
      portName = "tenant-${tenant}";
      matches =
        builtins.filter
          (entry: builtins.hasAttr portName (entry.value.ports or { }))
          (lib.attrsToList (accessNodes inventory siteName));
    in
    firstOrNull matches;

  tenantRuntime =
    inventory: siteName: tenant:
    let
      nodeEntry = accessNodeEntryForTenant inventory siteName tenant;
      port = nodeEntry.value.ports."tenant-${tenant}";
    in
    if nodeEntry == null then
      null
    else
      {
        bridge = port.attach.bridge;
      };

  endpointIsEmulatable =
    inventory: siteName: endpoint:
    let
      runtime = tenantRuntime inventory siteName endpoint.tenant;
      addr4 = endpointAddress inventory endpoint.name "ipv4";
      addr6 = endpointAddress inventory endpoint.name "ipv6";
    in
    endpoint.kind == "host"
    && runtime != null
    && builtins.elem endpoint.tenant (accessTenants inventory siteName)
    && addr4 != null
    && addr6 != null;

  endpointClient =
    { intent
    , inventory
    , siteName
    , endpointAddressing
    }:
    endpoint:
    let
      site = intent.esp.${siteName};
      runtime = tenantRuntime inventory siteName endpoint.tenant;
      prefix = tenantPrefixFor site endpoint.tenant;
      addr4 = endpointAddress inventory endpoint.name "ipv4";
      addr6 = endpointAddress inventory endpoint.name "ipv6";
      name = fixtureName siteName endpoint.name;
      gw4 = stripCidr prefix.ipv4;
      gw6 = stripCidr prefix.ipv6;
    in
    {
      inherit name;
      value =
        if endpointAddressing == "dhcp" then
          mkDhcpClient {
            inherit name;
            bridge = runtime.bridge;
            dnsServers = [
              gw4
              gw6
            ];
          }
        else
          mkStaticClient {
            inherit name gw4 gw6;
            bridge = runtime.bridge;
            addr4 = "${addr4}/${builtins.elemAt (lib.splitString "/" prefix.ipv4) 1}";
            addr6 = "${addr6}/${builtins.elemAt (lib.splitString "/" prefix.ipv6) 1}";
          };
    };

  buildSiteClients =
    { intent
    , inventory
    , siteName
    , endpointAddressing ? "static"
    ,
    }:
    let
      site = intent.esp.${siteName};
    in
    builtins.listToAttrs (
      map
        (endpoint:
          endpointClient {
            inherit intent inventory siteName endpointAddressing;
          } endpoint)
        (builtins.filter
          (endpoint: endpointIsEmulatable inventory siteName endpoint)
          (site.ownership.endpoints or [ ]))
    );
in
{
  buildFromPaths =
    { intentPath
    , inventoryPath
    , sopsPath ? null
    , fixture ? { }
    ,
    }:
    let
      intent = import intentPath;
      inventory = import inventoryPath;
      hostName = fixture.hostName or "s-router-test-clients";
      primarySite = fixture.siteName or "nixos";
      clientAccessCount = fixture.clientAccessCount or 2;
    in
    {
      inherit intent inventory clientAccessCount;

      hostNetwork = {
        inherit hostName;
        bridgeNameMap = { };
        bridges = { };
        netdevs = { };
        networks = {
          "30-vlan2".networkConfig.DHCP = "ipv4";
        };
      };

      containers =
        buildSiteClients {
          inherit intent inventory;
          siteName = primarySite;
          endpointAddressing = "static";
        }
        // buildSiteClients {
          inherit intent inventory;
          siteName = "clab";
          endpointAddressing = "dhcp";
        };
    };
}
