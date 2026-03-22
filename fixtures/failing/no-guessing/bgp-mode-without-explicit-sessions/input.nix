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
                    unit = "core-1";
                    local.ipv4 = "10.0.0.1";
                  }
                  {
                    unit = "core-2";
                    local.ipv4 = "10.0.0.2";
                  }
                ];
              }
            ];
            ordering = [
              [ "core-1" "core-2" ]
            ];
          };

          nodes = {
            core-1 = {
              role = "core";
              interfaces = {
                p2p0 = {
                  kind = "lan";
                };
              };
            };

            core-2 = {
              role = "core";
              interfaces = {
                p2p0 = {
                  kind = "lan";
                };
              };
            };
          };

          bgp = {
            mode = "bgp";
          };
        };
      };
    };
  };
}
