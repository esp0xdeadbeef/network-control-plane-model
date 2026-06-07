{ lib }:

{ intentPath
, inventoryPath
, sopsPath ? null
, fixture
}:

let
  intent = import intentPath;
  inventory = import inventoryPath;

  hostName = fixture.hostName;
  siteName = fixture.siteName;
in
{
  config = {
    system.stateVersion = lib.mkForce "25.11";

    environment.systemPackages = [ ];

    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.useHostResolvConf = lib.mkForce false;

    services.resolved.enable = lib.mkForce true;

    systemd.network.enable = true;
    systemd.network.wait-online.enable = false;
    systemd.network.netdevs = { };
    systemd.network.networks = {
      "30-vlan2".networkConfig.DHCP = "ipv4";
    };

    containers = { };

    _module.args.renderedHostNetwork = {
      inherit hostName;
      bridgeNameMap = { };
      bridges = { };
      netdevs = { };
      networks = {
        "30-vlan2".networkConfig.DHCP = "ipv4";
      };
      containers = { };
      clientAccessCount = 0;
      hostValidation = {
        requireDefaultRoutes = true;
        requireHostResolver = true;
        requirePublicIpv4Ping = true;
        requirePublicIpv6Ping = true;
      };
    };
  };

  inherit intent inventory siteName;
}
