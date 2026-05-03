{ common }:

let
  inherit (common) mod pow2;

  parseIPv4 =
    s:
    let
      m = builtins.match "([0-9]+)\\.([0-9]+)\\.([0-9]+)\\.([0-9]+)" (toString s);
      toOctet = x:
        let n = builtins.fromJSON x;
        in if n < 0 || n > 255 then null else n;
    in
    if m == null then
      null
    else
      let
        a = toOctet (builtins.elemAt m 0);
        b = toOctet (builtins.elemAt m 1);
        c = toOctet (builtins.elemAt m 2);
        d = toOctet (builtins.elemAt m 3);
      in
      if a == null || b == null || c == null || d == null then null else [ a b c d ];

  ipv4ToInt =
    octets:
    let
      a = builtins.elemAt octets 0;
      b = builtins.elemAt octets 1;
      c = builtins.elemAt octets 2;
      d = builtins.elemAt octets 3;
    in
    a * 16777216 + b * 65536 + c * 256 + d;

  ipv4FromInt =
    n:
    let
      a = builtins.div n 16777216;
      r1 = mod n 16777216;
      b = builtins.div r1 65536;
      r2 = mod r1 65536;
      c = builtins.div r2 256;
      d = mod r2 256;
    in
    [ a b c d ];

  renderIPv4 =
    octets:
    "${toString (builtins.elemAt octets 0)}.${toString (builtins.elemAt octets 1)}.${toString (builtins.elemAt octets 2)}.${toString (builtins.elemAt octets 3)}";

  ipv4NetworkBaseInt =
    { addrInt, prefixLen }:
    let
      block = pow2 (32 - prefixLen);
    in
    (builtins.div addrInt block) * block;

in
{
  inherit
    ipv4FromInt
    ipv4NetworkBaseInt
    ipv4ToInt
    parseIPv4
    renderIPv4
    ;
}
