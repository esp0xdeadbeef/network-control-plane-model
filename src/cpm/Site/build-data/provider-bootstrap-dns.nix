{ common
, helpers
,
}:

let
  inherit (helpers) isNonEmptyString requireAttrs requireList requireString;
  inherit (common) attrsOrEmpty failInventory;

  normalizeStringList = path: values:
    builtins.map
      (entry:
        let rendered = requireString "${path}[*]" entry;
        in if isNonEmptyString rendered then rendered else failInventory path "must not contain empty strings")
      (requireList path values);
in
{
  normalize = overlayPath: overlayCfg:
    let
      dns = attrsOrEmpty (overlayCfg.providerBootstrapDns or null);
      dnsPath = "${overlayPath}.providerBootstrapDns";
      forwarders = normalizeStringList "${dnsPath}.forwarders" (dns.forwarders or [ ]);
      routePreference =
        if dns ? routePreference then
          normalizeStringList "${dnsPath}.routePreference" dns.routePreference
        else
          [ "provider-bootstrap" ];
      allowedUpstreamClasses =
        if dns ? allowedUpstreamClasses then
          normalizeStringList "${dnsPath}.allowedUpstreamClasses" dns.allowedUpstreamClasses
        else
          [ "provider-bootstrap" ];
      _shape = if overlayCfg ? providerBootstrapDns then requireAttrs dnsPath overlayCfg.providerBootstrapDns else { };
      _hasForwarders =
        if overlayCfg ? providerBootstrapDns && forwarders == [ ] then
          failInventory "${dnsPath}.forwarders" "must define at least one bootstrap resolver address"
        else
          true;
    in
    if !(overlayCfg ? providerBootstrapDns) then
      { }
    else
      builtins.seq _shape (
        builtins.seq _hasForwarders {
          providerBootstrapDns = {
            source = "provider-bootstrap-dns";
            scope = "bootstrap-only";
            failClosed = true;
            fallbackToCustomerResolver = false;
            reusableByCustomerResolvers = false;
            forwarders = forwarders;
            routePreference = routePreference;
            allowedUpstreamClasses = allowedUpstreamClasses;
            routeContracts = builtins.map (forwarder: {
              dst = forwarder;
              source = "provider-bootstrap-dns";
              scope = "bootstrap-only";
            }) forwarders;
            policyMatrix = builtins.map (forwarder: {
              dst = forwarder;
              source = "provider-bootstrap-dns";
              scope = "bootstrap-only";
            }) forwarders;
          };
        }
      );
}
