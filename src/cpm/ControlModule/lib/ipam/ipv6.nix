{ lib, common }:

let
  inherit (common) digits mod pow2;

  parseHextet =
    s:
    let
      v = toString s;
      m = builtins.match "^[0-9A-Fa-f]{1,4}$" v;
      toNibble =
        c:
        let
          lc = lib.toLower c;
        in
        lib.lists.findFirstIndex (d: d == lc) null digits;
      step = acc: ch:
        let nib = toNibble ch;
        in if nib == null then null else acc * 16 + nib;
    in
    if m == null then null else builtins.foldl' step 0 (lib.strings.stringToCharacters v);

  splitNonEmpty = sep: s:
    lib.filter (x: x != "") (lib.splitString sep (toString s));

  parseIPv6 =
    s:
    let
      parts = lib.splitString "::" (toString s);
      leftRaw = builtins.elemAt parts 0;
      rightRaw = if builtins.length parts > 1 then builtins.elemAt parts 1 else "";
      hasDouble = builtins.length parts == 2;
      tooMany = builtins.length parts > 2;
      leftVals = map parseHextet (if leftRaw == "" then [ ] else splitNonEmpty ":" leftRaw);
      rightVals = map parseHextet (if rightRaw == "" then [ ] else splitNonEmpty ":" rightRaw);
      anyNull = lib.any (x: x == null) (leftVals ++ rightVals);
      missing = 8 - (builtins.length leftVals + builtins.length rightVals);
      full = leftVals ++ builtins.genList (_: 0) (if hasDouble then missing else 0) ++ rightVals;
    in
    if tooMany || anyNull || (hasDouble && missing < 0) || builtins.length full != 8 then null else full;

  ipv6ToInt = hextets:
    builtins.foldl' (acc: h: acc * 65536 + h) 0 hextets;

  ipv6FromInt =
    n:
    let
      step =
        acc:
        let
          h = mod acc.cur 65536;
        in
        { cur = builtins.div acc.cur 65536; out = [ h ] ++ acc.out; };
    in
    (builtins.foldl' (_: v: step v) { cur = n; out = [ ]; } (builtins.genList (i: i) 8)).out;

  toHex =
    n:
    if n == 0 then "0" else if n < 16 then builtins.elemAt digits n else (toHex (builtins.div n 16)) + (builtins.elemAt digits (mod n 16));

  renderIPv6 = hextets:
    lib.concatStringsSep ":" (map (h: toHex h) hextets);

  ipv6NetworkBaseInt =
    { addrInt, prefixLen }:
    let
      block = pow2 (128 - prefixLen);
    in
    (builtins.div addrInt block) * block;

in
{
  inherit
    ipv6FromInt
    ipv6NetworkBaseInt
    ipv6ToInt
    parseIPv6
    renderIPv6
    ;
}
