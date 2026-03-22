# ./fixtures/passing/minimal-explicit/input.nix
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
                    local = {
                      ipv4 = "10.0.0.1";
                    };
                  }
                  {
                    unit = "access-1";
                    local = {
                      ipv4 = "10.0.0.2";
                    };
                  }
                ];
                routingParticipation = false;
              }
            ];
            ordering = [
              [ "policy-1" "access-1" ]
            ];
          };

          transport = {
            overlays = {};
          };

          nodes = {
            policy-1 = {
              role = "policy";
              interfaces = {
                tenant0 = {
                  kind = "tenant";
                  tenant = "tenant-a";
                };
                uplink0 = {
                  kind = "wan";
                  upstream = "wan";
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
                  name = "wan";
                };
                action = "allow";
              }
            ];
          };

          policy = {
            interfaceTags = {
              tenant0 = "tenant-a";
              uplink0 = "wan";
            };
          };
        };
      };
    };
  };
}
