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
