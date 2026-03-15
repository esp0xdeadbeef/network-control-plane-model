{
  endpoints = {
    s-sigma = {
      zone = "mgmt";

      ipv4 = [ "10.20.10.10" ];

      ipv6 = [
        "fd42:dead:beef:10::10"
      ];
    };

    web01 = {
      zone = "admin";

      ipv4 = [ "10.20.15.10" ];

      ipv6 = [
        "fd42:dead:beef:15::10"
        # optional future GUA
        # "2001:db8:1234:15::10"
      ];
    };
  };
}
