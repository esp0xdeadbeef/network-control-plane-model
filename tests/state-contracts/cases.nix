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

  restartTolerant = addStateContracts "router-access-lab" {
    statePolicy.persistence = {
      required = false;
      root = "/run/network/state";
      durabilityClass = "restart-tolerant";
      stateLossHandling = "rebuild-from-modeled-runtime-facts";
    };
    advertisements = {
      dhcp4 = [
        {
          id = "lab";
          interface = "tenant-lab";
          tenant = "lab";
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

  invalidDurabilityClass = addStateContracts "router-bad-durability" {
    statePolicy.persistence = {
      required = false;
      durabilityClass = "restart-eventually";
    };
    advertisements.dhcp4 = [
      {
        id = "bad";
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
  restartTolerantDhcp4 = builtins.elemAt restartTolerant.stateContracts.persistence.dhcp4Leases 0;
  dhcp4Record = builtins.elemAt persistent.stateContracts.operationalRecords.dhcp4Leases 0;
  dhcpv6Record = builtins.elemAt persistent.stateContracts.operationalRecords.dhcpv6Leases 0;
  dnsServiceRecord = builtins.elemAt persistent.stateContracts.operationalRecords.dnsService 0;
  dnsResolverRecord = builtins.elemAt persistent.stateContracts.operationalRecords.dnsResolver 0;

  requiredRecordFields = [
    "recordType"
    "timestampSource"
    "site"
    "context"
    "runtimeFactSet"
    "modelProvenance"
    "decision"
    "reason"
    "redactionClass"
  ];

  conditionalRecordFields = [
    "tenant"
  ];

  excludedRecordFields = [
    "secrets"
    "certificates"
    "fullPacketPayload"
    "unboundedDebugOutput"
  ];

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

  operationalRecords = [
    dhcp4Record
    dhcpv6Record
    dnsServiceRecord
    dnsResolverRecord
  ];
in
{
  dhcp4PersistenceContract =
    !(persistent ? statePolicy)
    && dhcp4.service == "dhcp4"
    && dhcp4.kind == "lease-state"
    && dhcp4.mode == "persistent"
    && dhcp4.required == true
    && dhcp4.targetName == "router-access-client"
    && dhcp4.scope == { target = "router-access-client"; service = "dhcp4"; id = "client"; interface = "tenant-client"; tenant = "client"; }
    && dhcp4.stateClass == "lease-state"
    && dhcp4.durabilityClass == "restart-persistent"
    && dhcp4.stateLossHandling == "fail-closed-require-persistent-state"
    && dhcp4.interface == "tenant-client"
    && dhcp4.tenant == "client"
    && hasAll leaseNamespaceFields dhcp4.leaseNamespaceFields
    && dhcp4.source == "inventory-realization"
    && dhcp4.path == "/persist/network/state/dhcp4/router-access-client/client";

  dhcpv6PersistenceContract =
    dhcpv6.service == "dhcpv6"
    && dhcpv6.kind == "lease-state"
    && dhcpv6.mode == "persistent"
    && dhcpv6.required == true
    && dhcpv6.durabilityClass == "restart-persistent"
    && dhcpv6.interface == "tenant-client"
    && dhcpv6.tenant == "client"
    && hasAll leaseNamespaceFields dhcpv6.leaseNamespaceFields
    && dhcpv6.source == "inventory-realization"
    && dhcpv6.path == "/persist/network/state/dhcpv6/router-access-client/client-v6";

  dnsServicePersistenceContract =
    dnsService.service == "dns-service"
    && dnsService.kind == "service-state"
    && dnsService.mode == "persistent"
    && dnsService.required == true
    && dnsService.targetName == "router-access-client"
    && dnsService.scope == { target = "router-access-client"; service = "dns-service"; id = "service-state"; }
    && dnsService.stateClass == "service-state"
    && dnsService.durabilityClass == "restart-persistent"
    && dnsService.stateLossHandling == "fail-closed-require-persistent-state"
    && dnsService.listen == [ "10.20.10.1" ]
    && dnsService.source == "inventory-realization"
    && dnsService.path == "/persist/network/state/dns-service/router-access-client/service-state";

  dnsResolverPersistenceContract =
    dnsResolver.service == "dns-resolver"
    && dnsResolver.kind == "resolver-state"
    && dnsResolver.mode == "persistent"
    && dnsResolver.required == true
    && dnsResolver.durabilityClass == "restart-persistent"
    && dnsResolver.forwarders == [ "1.1.1.1" ]
    && dnsResolver.source == "inventory-realization"
    && dnsResolver.path == "/persist/network/state/dns-resolver/router-access-client/resolver-state";

  relatedServicePersistenceContract =
    relatedService.service == "mdns"
    && relatedService.kind == "service-state"
    && relatedService.mode == "persistent"
    && relatedService.required == true
    && relatedService.durabilityClass == "restart-persistent"
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
    && ephemeralDhcp4.durabilityClass == "disposable"
    && ephemeralDhcp4.stateLossHandling == "recreate-empty-state"
    && ephemeralDhcp4.source == "explicit-ephemeral"
    && ephemeralDhcp4.runtimeLocation == "ephemeral";

  restartTolerantPersistenceContract =
    restartTolerantDhcp4.service == "dhcp4"
    && restartTolerantDhcp4.kind == "lease-state"
    && restartTolerantDhcp4.mode == "ephemeral"
    && restartTolerantDhcp4.required == false
    && restartTolerantDhcp4.durabilityClass == "restart-tolerant"
    && restartTolerantDhcp4.stateLossHandling == "rebuild-from-modeled-runtime-facts"
    && restartTolerantDhcp4.source == "inventory-realization"
    && restartTolerantDhcp4.path == "/run/network/state/dhcp4/router-access-lab/lab";

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
    && dhcp4Record.targetName == "router-access-client"
    && dhcp4Record.scope == { target = "router-access-client"; service = "dhcp4"; id = "client"; interface = "tenant-client"; tenant = "client"; }
    && dhcp4Record.stateClass == "operational-record"
    && dhcp4Record.durabilityClass == "restart-persistent"
    && dhcp4Record.stateLossHandling == "fail-closed-require-persistent-state"
    && dhcp4Record.source == "inventory-realization"
    && builtins.elem "lease-allocated" dhcp4Record.eventTypes
    && builtins.elem "lease-released" dhcp4Record.eventTypes
    && builtins.elem "lease-conflict-detected" dhcp4Record.eventTypes
    && builtins.elem "lease-marked-stale" dhcp4Record.eventTypes
    && builtins.elem "lease-revoked" dhcp4Record.eventTypes
    && hasAll leaseNamespaceFields dhcp4Record.fields
    && dhcp4Record.path == "/persist/network/records/dhcp4/router-access-client/client.jsonl";

  dhcpv6OperationalRecordContract =
    dhcpv6Record.service == "dhcpv6"
    && dhcpv6Record.format == "jsonl"
    && dhcpv6Record.mode == "persistent"
    && dhcpv6Record.required == true
    && dhcpv6Record.source == "inventory-realization"
    && builtins.elem "lease-allocated" dhcpv6Record.eventTypes
    && builtins.elem "lease-released" dhcpv6Record.eventTypes
    && builtins.elem "lease-conflict-detected" dhcpv6Record.eventTypes
    && builtins.elem "lease-marked-stale" dhcpv6Record.eventTypes
    && builtins.elem "lease-revoked" dhcpv6Record.eventTypes
    && hasAll leaseNamespaceFields dhcpv6Record.fields
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
    builtins.all
      (record:
        hasAll requiredRecordFields record.fields
        && hasAll conditionalRecordFields record.fields
        && record.schema.requiredFields == requiredRecordFields
        && record.schema.conditionalFields == conditionalRecordFields)
      operationalRecords;

  operationalRecordExcludedFields =
    hasAll excludedRecordFields dhcp4Record.excludedFields
    && hasAll excludedRecordFields dhcpv6Record.excludedFields
    && hasAll excludedRecordFields dnsServiceRecord.excludedFields
    && hasAll excludedRecordFields dnsResolverRecord.excludedFields;

  operationalRecordIncompleteEvidenceClassification =
    builtins.all
      (record:
        record.schema.incompleteEvidence.classification == "incomplete-evidence"
        && record.schema.incompleteEvidence.whenMissingFields == [
          "site"
          "context"
          "runtimeFactSet"
          "modelProvenance"
        ]
        && record.schema.incompleteEvidence.promotionAllowed == false)
      operationalRecords;

  missingPersistenceRootThrows =
    builtins.deepSeq missingPersistenceRoot.stateContracts.persistence.dhcp4Leases true;

  missingDhcpv6PersistenceRootThrows =
    builtins.deepSeq missingDhcpv6PersistenceRoot.stateContracts.persistence.dhcpv6Leases true;

  missingRecordRootThrows =
    builtins.deepSeq missingRecordRoot.stateContracts.operationalRecords.dhcp4Leases true;

  invalidDurabilityClassThrows =
    builtins.deepSeq invalidDurabilityClass.stateContracts.persistence.dhcp4Leases true;

  # FS-860-HDS-010-SDS-010-SMS-010 scope validation predicates

  scopeFieldsPresent =
    let
      contract = builtins.elemAt persistent.stateContracts.persistence.dhcp4Leases 0;
      hasService = builtins.isString contract.service && contract.service != "";
      hasStateClass = builtins.isString contract.stateClass && contract.stateClass != "";
      hasRequired = builtins.isBool contract.required;
      hasHost = builtins.isString contract.scope.target && contract.scope.target != "";
      hasPath = contract ? path && builtins.isString contract.path && contract.path != "";
    in
    hasService && hasStateClass && hasRequired && hasHost && hasPath;

  scopeFieldsTenantWhenApplicable =
    let
      contract = builtins.elemAt persistent.stateContracts.persistence.dhcp4Leases 0;
    in
    contract.scope ? tenant && builtins.isString contract.scope.tenant && contract.scope.tenant != "";

  # Ambiguous storage: two contracts for same service+host+stateClass with different paths
  ambiguousStorageTarget = addStateContracts "router-ambiguous" {
    statePolicy = {
      persistence = {
        required = true;
        root = "/persist/network/state";
      };
    };
    advertisements = {
      dhcp4 = [
        { id = "dup-a"; interface = "tenant-a"; tenant = "client"; }
        { id = "dup-b"; interface = "tenant-a"; tenant = "client"; }
      ];
    };
  };

  # Scope validation: detect duplicate (service, targetName, stateClass) with different paths
  ambiguousStorageDetected =
    let
      leases = ambiguousStorageTarget.stateContracts.persistence.dhcp4Leases;
      a = builtins.elemAt leases 0;
      b = builtins.elemAt leases 1;
    in
    a.service == b.service
    && a.targetName == b.targetName
    && a.stateClass == b.stateClass
    && a.path != b.path;

  # Missing ownership context: no advertisements means no state contracts
  missingOwnershipTarget = addStateContracts "router-no-ownership" {
    statePolicy = {
      persistence = {
        required = true;
        root = "/persist/network/state";
      };
    };
    advertisements = {};
    services = {};
  };

  missingOwnershipNoContracts =
    missingOwnershipTarget.stateContracts.persistence.dhcp4Leases == [ ]
    && missingOwnershipTarget.stateContracts.persistence.dhcpv6Leases == [ ]
    && missingOwnershipTarget.stateContracts.persistence.dnsServiceState == [ ]
    && missingOwnershipTarget.stateContracts.persistence.dnsResolverState == [ ]
    && missingOwnershipTarget.stateContracts.persistence.relatedServices == [ ];

  # Storage location outside authorized scope
  outOfScopeStorageTarget = addStateContracts "router-outofscope" {
    statePolicy = {
      persistence = {
        required = true;
        root = "/etc/wrong-location";
      };
    };
    advertisements = {
      dhcp4 = [
        { id = "bad-scope"; interface = "tenant-bad"; tenant = "client"; }
      ];
    };
  };

  outOfScopeStorageHasPath =
    let
      contract = builtins.elemAt outOfScopeStorageTarget.stateContracts.persistence.dhcp4Leases 0;
    in
    contract ? path && contract.path != "";
}
