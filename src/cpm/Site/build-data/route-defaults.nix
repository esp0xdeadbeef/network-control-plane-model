{ attrsOrEmpty, defaultDst }:

let
  hasLanedDefaultWithSameVia =
    family: route: routes:
    let
      viaField = if family == 4 then "via4" else "via6";
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
    builtins.filter
      (
        route:
          !(
            builtins.isAttrs route
            && (route.dst or null) == defaultDst family
            && ((route.intent or { }).kind or null) == "default-reachability"
            && ((attrsOrEmpty (route.lane or null)).access or "") == ""
            && hasLanedDefaultWithSameVia family route routes
          )
      )
      routes;
}
