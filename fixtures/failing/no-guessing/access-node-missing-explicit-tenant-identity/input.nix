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
                    unit = "access-1";
                    local.ipv4 = "10.0.0.1";
                  }
                  {
                    unit = "policy-1";
                    local.ipv4 = "10.0.0.2";
                  }
                ];
              }
            ];
            ordering = [
              [ "access-1" "policy-1" ]
            ];
          };

          nodes = {
            access-1 = {
              role = "access";
              interfaces = {
                lan0 = {
                  kind = "lan";
                };
              };
            };

            policy-1 = {
              role = "policy";
              interfaces = {
                uplink0 = {
                  kind = "wan";
                  upstream = "wan";
                };
              };
            };
          };
        };
      };
    };
  };
}
