{ lib }:

let
  stripCidr =
    value:
    if builtins.isString value then builtins.head (lib.splitString "/" value) else null;

  ipv4PeerFor31 =
    address:
    let
      parts = if builtins.isString address then lib.splitString "." address else [ ];
      last = if builtins.length parts == 4 then builtins.fromJSON (builtins.elemAt parts 3) else null;
      peerLast = if last == null then null else if lib.mod last 2 == 0 then last + 1 else last - 1;
    in
    if peerLast == null then null else lib.concatStringsSep "." ((lib.take 3 parts) ++ [ (builtins.toString peerLast) ]);

  ipv6PeerFor127 =
    address:
    let
      len = if builtins.isString address then builtins.stringLength address else 0;
      prefix = builtins.substring 0 (len - 1) address;
      last = builtins.substring (len - 1) 1 address;
      peerLastByNibble = {
        "0" = "1";
        "1" = "0";
        "2" = "3";
        "3" = "2";
        "4" = "5";
        "5" = "4";
        "6" = "7";
        "7" = "6";
        "8" = "9";
        "9" = "8";
        a = "b";
        b = "a";
        c = "d";
        d = "c";
        e = "f";
        f = "e";
        A = "B";
        B = "A";
        C = "D";
        D = "C";
        E = "F";
        F = "E";
      };
    in
    if len == 0 || !(builtins.hasAttr last peerLastByNibble) then null else "${prefix}${peerLastByNibble.${last}}";
in
{
  peerForInterface =
    family: iface:
    if family == 4 then
      ipv4PeerFor31 (stripCidr (iface.addr4 or null))
    else
      ipv6PeerFor127 (stripCidr (iface.addr6 or null));
}
