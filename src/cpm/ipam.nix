{ lib }:

let
  mod = a: b: a - (builtins.div a b) * b;

  digits = [
    "0"
    "1"
    "2"
    "3"
    "4"
    "5"
    "6"
    "7"
    "8"
    "9"
    "a"
    "b"
    "c"
    "d"
    "e"
    "f"
  ];

  pow2 = n: builtins.foldl' (acc: _: acc * 2) 1 (builtins.genList (i: i) n);

  splitCIDR =
    cidr:
    let
      m = builtins.match "([^/]+)/([0-9]+)" (toString cidr);
    in
    if m == null then
      null
    else
      {
        addr = builtins.elemAt m 0;
        prefixLen = builtins.fromJSON (builtins.elemAt m 1);
      };

  # ---- IPv4 ----

  parseIPv4 =
    s:
    let
      m = builtins.match "([0-9]+)\\.([0-9]+)\\.([0-9]+)\\.([0-9]+)" (toString s);
      toOctet = x:
        let
          n = builtins.fromJSON x;
        in
        if n < 0 || n > 255 then null else n;
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
    let
      a = toString (builtins.elemAt octets 0);
      b = toString (builtins.elemAt octets 1);
      c = toString (builtins.elemAt octets 2);
      d = toString (builtins.elemAt octets 3);
    in
    "${a}.${b}.${c}.${d}";

  ipv4NetworkBaseInt =
    { addrInt, prefixLen }:
    let
      hostBits = 32 - prefixLen;
      block = pow2 hostBits;
    in
    (builtins.div addrInt block) * block;

  # ---- IPv6 ----

  # Minimal IPv6 parser/renderer for deterministic IPAM.
  # - Supports :: compression
  # - Does not support IPv4-mapped suffixes
  parseHextet =
    s:
    let
      # empty hextet is only valid when coming from :: expansion
      v = toString s;
      m = builtins.match "^[0-9A-Fa-f]{1,4}$" v;
      toNibble =
        c:
        let
          lc = lib.toLower c;
          idx =
            lib.lists.findFirstIndex (d: d == lc) null digits;
        in
        idx;
      chars = lib.strings.stringToCharacters v;
      step = acc: ch:
        let
          nib = toNibble ch;
        in
        if nib == null then null else acc * 16 + nib;
      parsed =
        if m == null then
          null
        else
          builtins.foldl' step 0 chars;
    in
    parsed;

  splitNonEmpty =
    sep: s:
    lib.filter (x: x != "") (lib.splitString sep (toString s));

  parseIPv6 =
    s:
    let
      raw = toString s;
      parts = lib.splitString "::" raw;
      leftRaw = builtins.elemAt parts 0;
      rightRaw = if builtins.length parts > 1 then builtins.elemAt parts 1 else "";
      hasDouble = builtins.length parts == 2;
      tooMany = builtins.length parts > 2;

      left = if leftRaw == "" then [ ] else splitNonEmpty ":" leftRaw;
      right = if rightRaw == "" then [ ] else splitNonEmpty ":" rightRaw;

      leftVals = map parseHextet left;
      rightVals = map parseHextet right;

      anyNull = lib.any (x: x == null) (leftVals ++ rightVals);
      missing = 8 - (builtins.length leftVals + builtins.length rightVals);
      zeros = builtins.genList (_: 0) (if hasDouble then missing else 0);
      full = leftVals ++ zeros ++ rightVals;
    in
    if tooMany || anyNull then
      null
    else if hasDouble && missing < 0 then
      null
    else if !hasDouble && builtins.length full != 8 then
      null
    else if hasDouble && builtins.length full != 8 then
      null
    else
      full;

  ipv6ToInt =
    hextets:
    builtins.foldl' (acc: h: acc * 65536 + h) 0 hextets;

  ipv6FromInt =
    n:
    let
      step =
        acc:
        let
          cur = acc.cur;
          out = acc.out;
          h = mod cur 65536;
          next = builtins.div cur 65536;
        in
        {
          cur = next;
          out = [ h ] ++ out;
        };
      acc0 = { cur = n; out = [ ]; };
      res = builtins.foldl' (_: v: step v) acc0 (builtins.genList (i: i) 8);
    in
    res.out;

  toHex =
    n:
    if n == 0 then
      "0"
    else
      let
        go =
          x:
          if x < 16 then
            builtins.elemAt digits x
          else
            (go (builtins.div x 16)) + (builtins.elemAt digits (mod x 16));
      in
      go n;

  renderIPv6 =
    hextets:
    lib.concatStringsSep ":" (map (h: toHex h) hextets);

  ipv6NetworkBaseInt =
    { addrInt, prefixLen }:
    let
      hostBits = 128 - prefixLen;
      block = pow2 hostBits;
    in
    (builtins.div addrInt block) * block;

  allocOne =
    {
      family,
      prefix,
      perNodePrefixLength,
      offset,
    }:
    let
      cidr = splitCIDR prefix;
    in
    if cidr == null then
      throw "ipam: prefix must be CIDR (got ${builtins.toJSON prefix})"
    else if family == 4 then
      let
        prefixLen = cidr.prefixLen;
        parsed = parseIPv4 cidr.addr;
      in
      if parsed == null then
        throw "ipam: invalid IPv4 prefix address '${toString cidr.addr}'"
      else if !(builtins.isInt prefixLen) || prefixLen < 0 || prefixLen > 32 then
        throw "ipam: invalid IPv4 prefix length '/${toString prefixLen}'"
      else if perNodePrefixLength != 32 then
        throw "ipam: only perNodePrefixLength=32 is supported for IPv4 right now"
      else
        let
          base = ipv4NetworkBaseInt { addrInt = ipv4ToInt parsed; inherit prefixLen; };
          cap = pow2 (32 - prefixLen);
          _cap =
            if offset < 0 || offset >= cap then
              throw "ipam: IPv4 offset ${toString offset} overflows ${toString prefix} capacity ${toString cap}"
            else
              true;
          ipInt = builtins.seq _cap (base + offset);
          addr = renderIPv4 (ipv4FromInt ipInt);
        in
        "${addr}/32"
    else if family == 6 then
      let
        prefixLen = cidr.prefixLen;
        parsed = parseIPv6 cidr.addr;
      in
      if parsed == null then
        throw "ipam: invalid IPv6 prefix address '${toString cidr.addr}'"
      else if !(builtins.isInt prefixLen) || prefixLen < 0 || prefixLen > 128 then
        throw "ipam: invalid IPv6 prefix length '/${toString prefixLen}'"
      else if perNodePrefixLength != 128 then
        throw "ipam: only perNodePrefixLength=128 is supported for IPv6 right now"
      else
        let
          base = ipv6NetworkBaseInt { addrInt = ipv6ToInt parsed; inherit prefixLen; };
          cap = pow2 (128 - prefixLen);
          _cap =
            if offset < 0 || offset >= cap then
              throw "ipam: IPv6 offset ${toString offset} overflows ${toString prefix} capacity ${toString cap}"
            else
              true;
          ipInt = builtins.seq _cap (base + offset);
          addr = renderIPv6 (ipv6FromInt ipInt);
        in
        "${addr}/128"
    else
      throw "ipam: invalid family ${toString family}";
in
{
  inherit
    splitCIDR
    parseIPv4
    parseIPv6
    renderIPv4
    renderIPv6
    allocOne
    ;
}
