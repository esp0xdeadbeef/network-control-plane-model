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
                    unit = "core-1";
                    local.ipv4 = "10.0.0.2";
                  }
                ];
              }
            ];
            ordering = [
              [ "policy-1" "core-1" ]
            ];
          };

          nodes = {
            policy-1 = {
              role = "policy";
              interfaces = {
                uplink0 = {
                  kind = "wan";
                };
              };
            };

            core-1 = {
              role = "core";
              interfaces = {
                p2p0 = {
                  kind = "lan";
                };
              };
            };
          };
        };
      };
    };
  };
}
