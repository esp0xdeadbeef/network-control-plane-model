{ attrsOrEmpty, defaultDst }:

let
  viaFieldFor = family: if family == 4 then "via4" else "via6";

  lanedDefaultViaKey =
    family: route:
    let
      viaField = viaFieldFor family;
    in
    builtins.toJSON {
      dst = route.dst or null;
      via = route.${viaField} or null;
    };

  hasLanedDefaultWithSameVia =
    family: route: routes:
    let
      viaField = viaFieldFor family;
    in
    builtins.any
      (
        other:
        builtins.isAttrs other
        && (other.dst or null) == (route.dst or null)
        && (other.${viaField} or null) == (route.${viaField} or null)
        && ((attrsOrEmpty (other.lane or null)).access or "") != ""
      )
      routes;
in
{
  inherit hasLanedDefaultWithSameVia;
  dropDuplicateUnlanedDefaults =
    family: routes:
    let
      lanedDefaultViaSet =
        builtins.foldl'
          (
            acc: route:
            if
              builtins.isAttrs route
              && (route.dst or null) == defaultDst family
              && ((attrsOrEmpty (route.lane or null)).access or "") != ""
            then
              acc // {
                ${lanedDefaultViaKey family route} = true;
              }
            else
              acc
          )
          { }
          routes;
    in
    builtins.filter
      (
        route:
          !(
            builtins.isAttrs route
            && (route.dst or null) == defaultDst family
            && ((route.intent or { }).kind or null) == "default-reachability"
            && ((attrsOrEmpty (route.lane or null)).access or "") == ""
            && builtins.hasAttr (lanedDefaultViaKey family route) lanedDefaultViaSet
          )
      )
      routes;
}
