let
  flake = builtins.getFlake ("path:" + toString ../..);
  system = builtins.currentSystem;
  pkgs = import flake.inputs.nixpkgs { inherit system; };
  lib = pkgs.lib;
  helpers = import ../../src/cpm/cpm-contract-support.nix { inherit lib; };
  common = import ../../src/cpm/ControlModule/lib/common.nix { inherit helpers; };
  addStateContracts = import ../../src/cpm/ControlModule/runtime-targets/state-contracts.nix { inherit common; };

  hasAll = expected: actual:
    builtins.all (field: builtins.elem field actual) expected;

  persistent = addStateContracts "router-access-client" {
    statePolicy = {
      persistence = {
        required = true;
        root = "/persist/network/state";
      };
      operationalRecords = {
        required = true;
        root = "/persist/network/records";
      };
    };
    advertisements = {
      dhcp4 = [
        {
          id = "client";
          interface = "tenant-client";
          tenant = "client";
        }
      ];
      dhcpv6 = [
        {
          id = "client-v6";
          interface = "tenant-client";
          tenant = "client";
        }
      ];
    };
    services = {
      dns = {
        listen = [ "10.20.10.1" ];
        forwarders = [ "1.1.1.1" ];
      };
      mdns = {
        enabled = true;
      };
    };
  };

  ephemeral = addStateContracts "router-access-guest" {
    advertisements = {
      dhcp4 = [
        {
          id = "guest";
          interface = "tenant-guest";
          tenant = "guest";
        }
      ];
    };
  };

  noAdvertisements = addStateContracts "router-no-advertisements" {
    statePolicy.persistence.root = "/persist/network/state";
  };

  noDnsService = addStateContracts "router-no-dns-service" {
    statePolicy.persistence.root = "/persist/network/state";
    services.mdns.enabled = true;
  };

  missingPersistenceRoot = addStateContracts "router-bad-state" {
    statePolicy.persistence.required = true;
    advertisements.dhcp4 = [
      {
        id = "bad";
        interface = "tenant-bad";
      }
    ];
  };

  missingRecordRoot = addStateContracts "router-bad-records" {
    statePolicy.operationalRecords.required = true;
    advertisements.dhcp4 = [
      {
        id = "bad";
        interface = "tenant-bad";
      }
    ];
  };

  missingDhcpv6PersistenceRoot = addStateContracts "router-bad-v6-state" {
    statePolicy.persistence.required = true;
    advertisements.dhcpv6 = [
      {
        id = "bad-v6";
        interface = "tenant-bad";
      }
    ];
  };

  dhcp4 = builtins.elemAt persistent.stateContracts.persistence.dhcp4Leases 0;
  dhcpv6 = builtins.elemAt persistent.stateContracts.persistence.dhcpv6Leases 0;
  dnsService = builtins.elemAt persistent.stateContracts.persistence.dnsServiceState 0;
  dnsResolver = builtins.elemAt persistent.stateContracts.persistence.dnsResolverState 0;
  relatedService = builtins.elemAt persistent.stateContracts.persistence.relatedServices 0;
  ephemeralDhcp4 = builtins.elemAt ephemeral.stateContracts.persistence.dhcp4Leases 0;
  dhcp4Record = builtins.elemAt persistent.stateContracts.operationalRecords.dhcp4Leases 0;
  dhcpv6Record = builtins.elemAt persistent.stateContracts.operationalRecords.dhcpv6Leases 0;
  dnsServiceRecord = builtins.elemAt persistent.stateContracts.operationalRecords.dnsService 0;
  dnsResolverRecord = builtins.elemAt persistent.stateContracts.operationalRecords.dnsResolver 0;

  requiredRecordFields = [
    "time"
    "node"
    "service"
    "eventType"
    "clientOrAddress"
    "action"
    "result"
    "severity"
  ];

  excludedRecordFields = [
    "secrets"
    "certificates"
    "fullPacketPayload"
    "unboundedDebugOutput"
  ];
in
{
  dhcp4PersistenceContract =
    !(persistent ? statePolicy)
    && dhcp4.service == "dhcp4"
    && dhcp4.kind == "lease-state"
    && dhcp4.mode == "persistent"
    && dhcp4.required == true
    && dhcp4.interface == "tenant-client"
    && dhcp4.tenant == "client"
    && dhcp4.source == "inventory-realization"
    && dhcp4.path == "/persist/network/state/dhcp4/router-access-client/client";

  dhcpv6PersistenceContract =
    dhcpv6.service == "dhcpv6"
    && dhcpv6.kind == "lease-state"
    && dhcpv6.mode == "persistent"
    && dhcpv6.required == true
    && dhcpv6.interface == "tenant-client"
    && dhcpv6.tenant == "client"
    && dhcpv6.source == "inventory-realization"
    && dhcpv6.path == "/persist/network/state/dhcpv6/router-access-client/client-v6";

  dnsServicePersistenceContract =
    dnsService.service == "dns-service"
    && dnsService.kind == "service-state"
    && dnsService.mode == "persistent"
    && dnsService.required == true
    && dnsService.listen == [ "10.20.10.1" ]
    && dnsService.source == "inventory-realization"
    && dnsService.path == "/persist/network/state/dns-service/router-access-client/service-state";

  dnsResolverPersistenceContract =
    dnsResolver.service == "dns-resolver"
    && dnsResolver.kind == "resolver-state"
    && dnsResolver.mode == "persistent"
    && dnsResolver.required == true
    && dnsResolver.forwarders == [ "1.1.1.1" ]
    && dnsResolver.source == "inventory-realization"
    && dnsResolver.path == "/persist/network/state/dns-resolver/router-access-client/resolver-state";

  relatedServicePersistenceContract =
    relatedService.service == "mdns"
    && relatedService.kind == "service-state"
    && relatedService.mode == "persistent"
    && relatedService.required == true
    && relatedService.source == "inventory-realization"
    && relatedService.path == "/persist/network/state/mdns/router-access-client/service-state";

  explicitEphemeralContract =
    ephemeral.stateContracts.ephemeral.explicit == true
    && ephemeral.stateContracts.ephemeral.persistenceRequired == false
    && ephemeral.stateContracts.ephemeral.operationalRecordsRequired == false
    && ephemeralDhcp4.service == "dhcp4"
    && ephemeralDhcp4.kind == "lease-state"
    && ephemeralDhcp4.mode == "ephemeral"
    && ephemeralDhcp4.required == false
    && ephemeralDhcp4.source == "explicit-ephemeral"
    && ephemeralDhcp4.runtimeLocation == "ephemeral";

  persistentSummaryNotEphemeral =
    persistent.stateContracts.ephemeral.explicit == false
    && persistent.stateContracts.ephemeral.persistenceRequired == true
    && persistent.stateContracts.ephemeral.operationalRecordsRequired == true;

  dhcp4ExplicitInputOnly =
    noAdvertisements.stateContracts.persistence.dhcp4Leases == [ ];

  dhcpv6ExplicitInputOnly =
    noAdvertisements.stateContracts.persistence.dhcpv6Leases == [ ];

  dnsExplicitInputOnly =
    noDnsService.stateContracts.persistence.dnsServiceState == [ ]
    && noDnsService.stateContracts.persistence.dnsResolverState == [ ];

  dhcp4OperationalRecordContract =
    dhcp4Record.service == "dhcp4"
    && dhcp4Record.format == "jsonl"
    && dhcp4Record.mode == "persistent"
    && dhcp4Record.required == true
    && dhcp4Record.source == "inventory-realization"
    && builtins.elem "lease-allocated" dhcp4Record.eventTypes
    && builtins.elem "lease-released" dhcp4Record.eventTypes
    && dhcp4Record.path == "/persist/network/records/dhcp4/router-access-client/client.jsonl";

  dhcpv6OperationalRecordContract =
    dhcpv6Record.service == "dhcpv6"
    && dhcpv6Record.format == "jsonl"
    && dhcpv6Record.mode == "persistent"
    && dhcpv6Record.required == true
    && dhcpv6Record.source == "inventory-realization"
    && builtins.elem "lease-allocated" dhcpv6Record.eventTypes
    && builtins.elem "lease-released" dhcpv6Record.eventTypes
    && dhcpv6Record.path == "/persist/network/records/dhcpv6/router-access-client/client-v6.jsonl";

  dnsServiceOperationalRecordContract =
    dnsServiceRecord.service == "dns-service"
    && dnsServiceRecord.format == "jsonl"
    && dnsServiceRecord.mode == "persistent"
    && dnsServiceRecord.required == true
    && dnsServiceRecord.source == "inventory-realization"
    && builtins.elem "service-started" dnsServiceRecord.eventTypes
    && builtins.elem "forwarder-state-changed" dnsServiceRecord.eventTypes
    && dnsServiceRecord.path == "/persist/network/records/dns-service/router-access-client/service-state.jsonl";

  dnsResolverOperationalRecordContract =
    dnsResolverRecord.service == "dns-resolver"
    && dnsResolverRecord.format == "jsonl"
    && dnsResolverRecord.mode == "persistent"
    && dnsResolverRecord.required == true
    && dnsResolverRecord.source == "inventory-realization"
    && builtins.elem "query-forwarded" dnsResolverRecord.eventTypes
    && builtins.elem "upstream-failed" dnsResolverRecord.eventTypes
    && dnsResolverRecord.path == "/persist/network/records/dns-resolver/router-access-client/resolver-state.jsonl";

  operationalRecordContextFields =
    hasAll requiredRecordFields dhcp4Record.fields
    && hasAll requiredRecordFields dhcpv6Record.fields
    && hasAll requiredRecordFields dnsServiceRecord.fields
    && hasAll requiredRecordFields dnsResolverRecord.fields;

  operationalRecordExcludedFields =
    hasAll excludedRecordFields dhcp4Record.excludedFields
    && hasAll excludedRecordFields dhcpv6Record.excludedFields
    && hasAll excludedRecordFields dnsServiceRecord.excludedFields
    && hasAll excludedRecordFields dnsResolverRecord.excludedFields;

  missingPersistenceRootThrows =
    builtins.deepSeq missingPersistenceRoot.stateContracts.persistence.dhcp4Leases true;

  missingDhcpv6PersistenceRootThrows =
    builtins.deepSeq missingDhcpv6PersistenceRoot.stateContracts.persistence.dhcpv6Leases true;

  missingRecordRootThrows =
    builtins.deepSeq missingRecordRoot.stateContracts.operationalRecords.dhcp4Leases true;
}
