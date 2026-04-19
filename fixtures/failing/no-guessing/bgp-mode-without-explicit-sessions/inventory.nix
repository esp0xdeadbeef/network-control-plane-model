{
  controlPlane = {
    sites = {
      acme = {
        ams = {
          routing = {
            mode = "bgp";
            bgp = {
              topology = "policy-rr";
            };
          };
        };
      };
    };
  };
}
