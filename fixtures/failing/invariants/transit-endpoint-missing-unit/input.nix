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
                    local.ipv4 = "10.0.0.1";
                  }
                  {
                    unit = "b";
                    local.ipv4 = "10.0.0.2";
                  }
                ];
              }
            ];
            ordering = [
              [ "a" "b" ]
            ];
          };
        };
      };
    };
  };
}
