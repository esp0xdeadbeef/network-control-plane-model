# FS-320-HDS-010-SDS-010-SMS-030 and FS-984-HDS-010-SDS-010-SMS-010:
# negative fixture proving missing interface kind is rejected instead of inferred
# from runtime-like names such as eth0.
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
                    unit = "node-a";
                    local.ipv4 = "10.0.0.1";
                  }
                  {
                    unit = "node-b";
                    local.ipv4 = "10.0.0.2";
                  }
                ];
              }
            ];
            ordering = [
              [ "node-a" "node-b" ]
            ];
          };

          nodes = {
            node-a = {
              role = "core";
              interfaces = {
                eth0 = { };
              };
            };

            node-b = {
              role = "core";
              interfaces = {
                eth0 = {
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
