{ common }:

let
  primitives = import ./state-contract-primitives.nix { inherit common; };
  inherit (primitives)
    attrsOrEmpty
    listOrEmpty
    persistenceContract
    persistenceRequired
    recordContract
    recordRequired
    ;

  statePolicyFor = target:
    attrsOrEmpty (target.statePolicy or null);

  persistencePolicyFor = statePolicy:
    attrsOrEmpty (statePolicy.persistence or null);

  recordPolicyFor = statePolicy:
    attrsOrEmpty (statePolicy.operationalRecords or null);

  leaseNamespaceRecordFields = [
    "namespace"
    "namespaceOwner"
    "requesterScope"
    "recordClass"
    "deniedClasses"
    "conflict"
    "stale"
    "revocation"
  ];

  leaseOperationalEventTypes = [
    "lease-allocated"
    "lease-renewed"
    "lease-released"
    "lease-conflict-detected"
    "lease-marked-stale"
    "lease-revoked"
  ];

  dhcp4LeaseContract = targetName: persistencePolicy: entry:
    persistenceContract targetName persistencePolicy "dhcp4" (entry.id or entry.interface or "unknown") ({
      kind = "lease-state";
      interface = entry.interface or "";
      tenant = entry.tenant or "";
      leaseNamespaceFields = [
        "namespace"
        "namespaceOwner"
        "requesterScope"
        "recordClass"
        "deniedClasses"
        "conflict"
        "stale"
        "revocation"
      ];
    } // (if builtins.isAttrs (entry.leaseState or null) then {
      path = entry.leaseState.path or "";
    } else { }));

  dhcpv6LeaseContract = targetName: persistencePolicy: entry:
    persistenceContract targetName persistencePolicy "dhcpv6" (entry.id or entry.interface or "unknown") ({
      kind = "lease-state";
      interface = entry.interface or "";
      tenant = entry.tenant or "";
      leaseNamespaceFields = [
        "namespace"
        "namespaceOwner"
        "requesterScope"
        "recordClass"
        "deniedClasses"
        "conflict"
        "stale"
        "revocation"
      ];
    } // (if builtins.isAttrs (entry.leaseState or null) then {
      path = entry.leaseState.path or "";
    } else { }));

  dnsStateContracts = targetName: persistencePolicy: dns:
    if dns == { } then
      { dnsServiceState = [ ]; dnsResolverState = [ ]; }
    else
      {
        dnsServiceState = [
          (persistenceContract targetName persistencePolicy "dns-service" "service-state" {
            kind = "service-state";
            listen = listOrEmpty (dns.listen or null);
          })
        ];
        dnsResolverState = [
          (persistenceContract targetName persistencePolicy "dns-resolver" "resolver-state" {
            kind = "resolver-state";
            forwarders = listOrEmpty (dns.forwarders or null);
          })
        ];
      };

  relatedServiceContracts = targetName: persistencePolicy: services:
    builtins.concatMap
      (serviceName:
        if serviceName == "dns" then
          [ ]
        else
          [
            (persistenceContract targetName persistencePolicy serviceName "service-state" {
              kind = "service-state";
            })
          ])
      (builtins.attrNames services);

  dhcp4RecordContract = targetName: recordPolicy: entry:
    recordContract targetName recordPolicy "dhcp4" (entry.id or entry.interface or "unknown") {
      eventTypes = leaseOperationalEventTypes;
      fields = leaseNamespaceRecordFields;
      interface = entry.interface or "";
      tenant = entry.tenant or "";
    };

  dhcpv6RecordContract = targetName: recordPolicy: entry:
    recordContract targetName recordPolicy "dhcpv6" (entry.id or entry.interface or "unknown") {
      eventTypes = leaseOperationalEventTypes;
      fields = leaseNamespaceRecordFields;
      interface = entry.interface or "";
      tenant = entry.tenant or "";
    };

  dnsRecordContracts = targetName: recordPolicy: dns:
    if dns == { } then
      { dnsService = [ ]; dnsResolver = [ ]; }
    else
      {
        dnsService = [
          (recordContract targetName recordPolicy "dns-service" "service-state" {
            eventTypes = [ "service-started" "service-stopped" "forwarder-state-changed" ];
          })
        ];
        dnsResolver = [
          (recordContract targetName recordPolicy "dns-resolver" "resolver-state" {
            eventTypes = [ "query-forwarded" "upstream-failed" "cache-state-changed" ];
          })
        ];
      };

  buildStateContracts = targetName: target:
    let
      statePolicy = statePolicyFor target;
      persistencePolicy = persistencePolicyFor statePolicy;
      recordPolicy = recordPolicyFor statePolicy;
      advertisements = attrsOrEmpty (target.advertisements or null);
      dhcp4 = listOrEmpty (advertisements.dhcp4 or null);
      dhcpv6 = listOrEmpty (advertisements.dhcpv6 or null);
      services = attrsOrEmpty (target.services or null);
      dns = attrsOrEmpty (services.dns or null);
      dnsPersistence = dnsStateContracts targetName persistencePolicy dns;
      dnsRecords = dnsRecordContracts targetName recordPolicy dns;
    in
    {
      persistence = {
        dhcp4Leases = builtins.map (dhcp4LeaseContract targetName persistencePolicy) dhcp4;
        dhcpv6Leases = builtins.map (dhcpv6LeaseContract targetName persistencePolicy) dhcpv6;
        inherit (dnsPersistence) dnsServiceState dnsResolverState;
        relatedServices = relatedServiceContracts targetName persistencePolicy services;
      };
      operationalRecords = {
        dhcp4Leases = builtins.map (dhcp4RecordContract targetName recordPolicy) dhcp4;
        dhcpv6Leases = builtins.map (dhcpv6RecordContract targetName recordPolicy) dhcpv6;
        inherit (dnsRecords) dnsService dnsResolver;
      };
      ephemeral = {
        explicit = !(persistenceRequired persistencePolicy);
        persistenceRequired = persistenceRequired persistencePolicy;
        operationalRecordsRequired = recordRequired recordPolicy;
      };
    };

in
targetName: target:
(builtins.removeAttrs target [ "statePolicy" ])
  // {
  stateContracts = buildStateContracts targetName target;
}
