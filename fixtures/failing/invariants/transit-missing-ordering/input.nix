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
                    unit = "a";
                    local.ipv4 = "10.0.0.1";
                  }
                  {
                    unit = "b";
                    local.ipv4 = "10.0.0.2";
                  }
                ];
              }
            ];
          };
        };
      };
    };
  };
}
