{
  enterprise = {
    esp0xdeadbeef = {
      site = {
        site-a = {
          transit = {
            adjacencies = [
              {
                kind = "p2p";
                link = "transit-policy-edge";
                endpoints = [
                  {
                    unit = "s-router-policy";
                    local = {
                      ipv4 = "169.254.100.1";
                      ipv6 = null;
                    };
                  }
                  {
                    unit = "s-router-edge";
                    local = {
                      ipv4 = "169.254.100.2";
                      ipv6 = null;
                    };
                  }
                ];
                routingParticipation = false;
              }
            ];

            ordering = [
              [ "s-router-policy" "s-router-edge" ]
            ];
          };

          transport = {
            overlays = { };
          };
        };
      };
    };
  };
}
