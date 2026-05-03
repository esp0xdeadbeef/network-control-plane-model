{ lib }:

let
  mod = a: b: a - (builtins.div a b) * b;
  digits = [
    "0" "1" "2" "3" "4" "5" "6" "7"
    "8" "9" "a" "b" "c" "d" "e" "f"
  ];
  pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);
  splitCIDR =
    cidr:
    let
      m = builtins.match "([^/]+)/([0-9]+)" (toString cidr);
    in
    if m == null then null else { addr = builtins.elemAt m 0; prefixLen = builtins.fromJSON (builtins.elemAt m 1); };
in
{
  inherit
    digits
    mod
    pow2
    splitCIDR
    ;
}
