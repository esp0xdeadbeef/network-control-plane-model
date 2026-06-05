{ helpers
, sitePath
, ipam
, advertisementHelpers
, advertisementContext
,
}:

let
  binderSourceAudit = import ../../binder-source-audit.nix { inherit helpers; };
  reservationModule = import ./reservations.nix {
    inherit helpers ipam advertisementHelpers binderSourceAudit;
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
