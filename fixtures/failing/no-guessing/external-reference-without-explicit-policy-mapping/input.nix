{
  enterprise = {
    acme = {
      site = {
        ams = {
          transit = {
            adjacencies = [
              {
                endpoints = [
                  {
                    unit = "policy-1";
                    local.ipv4 = "10.0.0.1";
                  }
                  {
                    unit = "access-1";
                    local.ipv4 = "10.0.0.2";
                  }
                ];
              }
            ];
            ordering = [
              [ "policy-1" "access-1" ]
            ];
          };

          nodes = {
            policy-1 = {
              role = "policy";
              interfaces = {
                tenant0 = {
                  kind = "tenant";
                  tenant = "tenant-a";
                };
              };
            };

            access-1 = {
              role = "access";
              interfaces = {
                tenant0 = {
                  kind = "tenant";
                  tenant = "tenant-a";
                };
              };
            };
          };

          communicationContract = {
            allowedRelations = [
              {
                from = {
                  kind = "tenant";
                  name = "tenant-a";
                };
                to = {
                  kind = "external";
                  name = "internet";
                };
                action = "allow";
              }
            ];
          };

          policy = {
            interfaceTags = {
              tenant0 = "tenant-a";
            };
          };
        };
      };
    };
  };
}
