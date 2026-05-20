{ common }:

let
  inherit (common) listOrEmpty;

  routeFor =
    family: route:
    let
      viaField = if family == 4 then "via4" else "via6";
    in
    {
      dst = route.prefix or route.dst or null;
      proto = "upstream";
      intent = {
        kind =
          if (family == 4 && (route.prefix or route.dst or null) == "0.0.0.0/0")
             || (family == 6 && (route.prefix or route.dst or null) == "::/0")
          then
            "default-reachability"
          else
            "uplink-learned-reachability";
        source = "explicit-uplink-static";
      };
      ${viaField} = route.via or route.${viaField} or null;
    };
in
uplinkCfg:
let
  staticRoutes = ((uplinkCfg.static or { }).routes or { });
in
{
  ipv4 = builtins.map (routeFor 4) (listOrEmpty (staticRoutes.ipv4 or null));
  ipv6 = builtins.map (routeFor 6) (listOrEmpty (staticRoutes.ipv6 or null));
}
