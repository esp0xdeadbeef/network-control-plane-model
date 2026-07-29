# GAMP-ID: FS-560-HDS-010-SDS-010-SMS-050
# GAMP-SCOPE: software-module-construction
#
# Protected Reservation Name Materialization — CPM Module Contract
#
# This module is the owning CPM implementation artifact for SMS-050.
# It normalizes the non-secret protected reservation namespace publication
# authority and derives the canonical source kind ("protected-reservation-set")
# and source family from the enclosing validated DHCP/DHCPv6 reservation source.
#
# The normalization is performed by normalizeNamePublication (see reservations.nix
# in this directory).  The function:
#
#   normalizeNamePublication :: familyName -> entryPath -> tenantName -> rawPublication
#
# derives:
#   source       = "protected-reservation-set"       (never from inventory)
#   sourceFamily = familyName                          (ipv4 or ipv6 from DHCP family)
#
# Protected hostname, MAC, IPv4, IPv6 IID/address, DUID, and IAID values
# shall not enter the CPM normalization layer.  The function rejects:
#   - records, hostname, mac, ipv4, ipv6, or other inventory-side protected fields
#   - wildcard requester scopes ("*")
#   - owner scope mismatches with the served tenant
#   - invalid record class values outside {A, AAAA, PTR}
#   - duplicate record classes
#
# The normalized non-secret publication authority is carried through
# network-realization-model into a schema-validated canonical bundle.
# The protected runtime value enters only via one validated platform binding
# and shall never become canonical plaintext.
#
# Module Responsibility mapping (SMS-050 predicate IDs):
#   001 — Bind to namespace owner, requester scopes, record classes, publication behavior
#   002 — Accept absent/disabled publication (null input → null output)
#   003 — Preserve source as opaque protected reference (schema/sourceClass/sourceFile only)
#   004 — Derive source kind + family from enclosing reservation source (no inventory duplication)
#
# See also:
#   dns-contracts.nix  — projects publication → DNS protectedReservationPublications
#   reservations.nix   — contains normalizeNamePublication implementation
#   runtime-reservation-materializer.py (NixOS)  — runtime A/AAAA/PTR materialization
#   protected-reservation-materializer.py (CLAB) — runtime A/AAAA/PTR materialization
#   dns-services.nix                            — protectedReservationLocalZoneSettings

{ helpers
, ipam
, advertisementHelpers
, binderSourceAudit
,
}:

let
  reservationModule = import ./reservations.nix {
    inherit helpers ipam advertisementHelpers binderSourceAudit;
  };
in
{
  inherit (reservationModule)
    normalizeNamePublication
    resolveReservationSource
    ;
}

