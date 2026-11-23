{ helpers }:

let
  inherit (helpers) isNonEmptyString sortedNames;

  attrsOrEmpty = value:
    if builtins.isAttrs value then value else { };

  listOrEmpty = value:
    if builtins.isList value then value else [ ];

  uniqueStrings =
    values:
    sortedNames (
      builtins.listToAttrs (
        builtins.map
          (value: {
            name = value;
            value = true;
          })
          (builtins.filter isNonEmptyString values)
      )
    );

  # A route list is a SET of routes: two entries for the same (dst, gateway,
  # table, metric) describe one installed route, and publishing both makes every
  # consumer install it twice. Measured on wireguard-provider-overlay,
  # s-router-access-admin: `10.20.10.0/24` appeared twice in one interface's
  # `routes.ipv4` after `addRoutesForTarget` merged the interface's own routes with
  # the ones a dnsRule copied onto it, and the renderer then reported those as
  # duplicate occurrences (FS-310-HDS-020-SDS-010-SMS-060).
  #
  # Deduplicate on the fields that identify an installed route. Anything the
  # record does not carry is compared as null, so two records that differ only in
  # fields the kernel does not use still collapse -- deliberately: they are the same
  # route on the box.
  routeIdentity =
    r:
    let
      str = v: if v == null then "-" else toString v;
    in
    builtins.concatStringsSep "|" [
      (str (r.dst or null))
      (str (r.gateway or null))
      (str (r.table or null))
      (str (r.metric or null))
    ];
  uniqueRoutes =
    rs:
    let
      # keep the first occurrence of each identity, in order. Implemented with
      # foldl' over an accumulator so it needs no `lib` here, and so the result is
      # deterministic by input order rather than by attribute iteration.
      step =
        acc: r:
        let
          id = routeIdentity r;
        in
        if builtins.hasAttr id acc.seen then
          acc
        else
          {
            seen = acc.seen // { ${id} = true; };
            out = acc.out ++ [ r ];
          };
    in
    (builtins.foldl' step { seen = { }; out = [ ]; } rs).out;
  mergeRoutes =
    base: extra: {
      ipv4 = uniqueRoutes (listOrEmpty (base.ipv4 or [ ]) ++ listOrEmpty (extra.ipv4 or [ ]));
      ipv6 = uniqueRoutes (listOrEmpty (base.ipv6 or [ ]) ++ listOrEmpty (extra.ipv6 or [ ]));
    };

in
{
  inherit
    attrsOrEmpty
    listOrEmpty
    mergeRoutes
    uniqueRoutes
    routeIdentity
    uniqueStrings
    ;
}
