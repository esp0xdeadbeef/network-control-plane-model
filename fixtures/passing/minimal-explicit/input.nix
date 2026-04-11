{
  meta = {
    networkForwardingModel = {
      name = "network-forwarding-model";
      schemaVersion = 9;
    };
  };

  enterprise = {
    acme = {
      site = {
        ams = {
          siteId = "ams";
          siteName = "acme.ams";
          attachments = [ ];
          policyNodeName = "policy-1";
          upstreamSelectorNodeName = "upstream-1";
          coreNodeNames = [ ];
          uplinkCoreNames = [ ];
          uplinkNames = [ ];
          domains = {
            tenants = [ ];
            externals = [ ];
          };
          tenantPrefixOwners = { };
          links = { };
          transit = {
            adjacencies = [ ];
            ordering = [ ];
          };
          communicationContract = {
            allowedRelations = [ ];
          };
          policy = {
            interfaceTags = { };
          };
          nodes = {
            policy-1 = {
              role = "policy";
              loopback = {
                ipv4 = "10.255.0.1/32";
                ipv6 = "fd00:ff::1/128";
              };
              interfaces = { };
            };

            upstream-1 = {
              role = "upstream-selector";
              loopback = {
                ipv4 = "10.255.0.2/32";
                ipv6 = "fd00:ff::2/128";
              };
              interfaces = { };
            };
          };
        };
      };
    };
  };
}
