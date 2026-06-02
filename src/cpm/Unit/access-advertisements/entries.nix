{ helpers
, sitePath
, ipam
, advertisementHelpers
, advertisementContext
,
}:

let
  reservationModule = import ./reservations.nix {
    inherit helpers ipam advertisementHelpers;
  };
  inherit (reservationModule) resolveReservations;

  dhcpv6 = import ./dhcpv6.nix {
    inherit helpers sitePath ipam advertisementHelpers advertisementContext resolveReservations;
  };

  buildExplicitDHCP4Entry = import ./dhcp4.nix {
    inherit helpers sitePath advertisementHelpers advertisementContext resolveReservations;
  };

  buildExplicitIPv6RaEntry = import ./ipv6-ra.nix {
    inherit helpers sitePath advertisementHelpers advertisementContext;
  };

in
{
  inherit
    buildExplicitDHCP4Entry
    buildExplicitIPv6RaEntry
    ;
  inherit (dhcpv6) buildExplicitDHCPv6Entry;
}
