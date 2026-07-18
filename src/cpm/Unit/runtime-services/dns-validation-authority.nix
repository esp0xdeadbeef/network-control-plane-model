{ lib, helpers, failInventory, isIpv4Address, isIpv6Address, }:

let
  inherit (helpers) isNonEmptyString requireAttrs requireList requireString;

  requiredString = path: value:
    let rendered = requireString path value;
    in if isNonEmptyString rendered then
      rendered
    else
      failInventory path "must not be empty";

  stringList = path: value:
    map (entry: requiredString "${path}[*]" entry) (requireList path value);

  addressList = family: path: value:
    let
      addresses = stringList path value;
      valid = if family == 4 then isIpv4Address else isIpv6Address;
    in if addresses == [ ] then
      failInventory path "must contain at least one address"
    else if builtins.all valid addresses then
      lib.unique addresses
    else
      failInventory path
      "must contain only IPv${toString family} address literals";

  ipv4CidrPattern = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\."
    + "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\."
    + "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\."
    + "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])/([0-9]|[12][0-9]|3[0-2])";

  ipv6CidrPattern =
    "([0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8])";

  cidr = family: path: value:
    let
      rendered = requiredString path value;
      pattern = if family == 4 then ipv4CidrPattern else ipv6CidrPattern;
    in if builtins.match pattern rendered != null then
      rendered
    else
      failInventory path "must be an IPv${toString family} CIDR literal";

  endpoint = path: value:
    let attrs = requireAttrs path value;
    in {
      nameServer =
        requiredString "${path}.nameServer" (attrs.nameServer or null);
      ipv4 = addressList 4 "${path}.ipv4" (attrs.ipv4 or [ ]);
      ipv6 = addressList 6 "${path}.ipv6" (attrs.ipv6 or [ ]);
    };
in {
  normalize = path: value:
    let
      authority = requireAttrs path value;
      kind = requiredString "${path}.kind" (authority.kind or null);
      scope = requiredString "${path}.scope" (authority.scope or null);
      traceId = requiredString "${path}.traceId" (authority.traceId or null);
      selectedUplink = requiredString "${path}.selectedUplink"
        (authority.selectedUplink or null);
      alternateUplinks = stringList "${path}.alternateUplinks"
        (authority.alternateUplinks or [ ]);

      providerInput =
        requireAttrs "${path}.provider" (authority.provider or null);
      provider4Input =
        requireAttrs "${path}.provider.ipv4" (providerInput.ipv4 or null);
      provider6Input =
        requireAttrs "${path}.provider.ipv6" (providerInput.ipv6 or null);
      provider = {
        bridge = requiredString "${path}.provider.bridge"
          (providerInput.bridge or null);
        ipv4 = {
          address = cidr 4 "${path}.provider.ipv4.address"
            (provider4Input.address or null);
          router = requiredString "${path}.provider.ipv4.router"
            (provider4Input.router or null);
          clientAddress = requiredString "${path}.provider.ipv4.clientAddress"
            (provider4Input.clientAddress or null);
          rangeStart = requiredString "${path}.provider.ipv4.rangeStart"
            (provider4Input.rangeStart or null);
          rangeEnd = requiredString "${path}.provider.ipv4.rangeEnd"
            (provider4Input.rangeEnd or null);
          leaseTime = requiredString "${path}.provider.ipv4.leaseTime"
            (provider4Input.leaseTime or null);
        };
        ipv6 = {
          address = cidr 6 "${path}.provider.ipv6.address"
            (provider6Input.address or null);
          router = requiredString "${path}.provider.ipv6.router"
            (provider6Input.router or null);
          prefix = cidr 6 "${path}.provider.ipv6.prefix"
            (provider6Input.prefix or null);
          leaseTime = requiredString "${path}.provider.ipv6.leaseTime"
            (provider6Input.leaseTime or null);
        };
      };

      rootInput = requireAttrs "${path}.root" (authority.root or null);
      root = endpoint "${path}.root" rootInput // {
        zone = requiredString "${path}.root.zone" (rootInput.zone or null);
      };
      delegationInput =
        requireAttrs "${path}.delegation" (authority.delegation or null);
      delegation = endpoint "${path}.delegation" delegationInput // {
        zone = requiredString "${path}.delegation.zone"
          (delegationInput.zone or null);
      };
      terminalInput =
        requireAttrs "${path}.terminal" (authority.terminal or null);
      terminal = {
        name =
          requiredString "${path}.terminal.name" (terminalInput.name or null);
        ipv4 =
          addressList 4 "${path}.terminal.ipv4" (terminalInput.ipv4 or [ ]);
        ipv6 =
          addressList 6 "${path}.terminal.ipv6" (terminalInput.ipv6 or [ ]);
      };
      trustInput = requireAttrs "${path}.trust" (authority.trust or null);
      trust = {
        mode = requiredString "${path}.trust.mode" (trustInput.mode or null);
      };
    in if kind != "controlled-iterative-hierarchy" then
      failInventory "${path}.kind" "must be controlled-iterative-hierarchy"
    else if scope != "harness" then
      failInventory "${path}.scope" "must be harness"
    else if alternateUplinks == [ ]
    || builtins.elem selectedUplink alternateUplinks then
      failInventory "${path}.alternateUplinks"
      "must contain an uplink distinct from selectedUplink"
    else if provider.bridge != selectedUplink then
      failInventory "${path}.provider.bridge" "must equal selectedUplink"
    else if !(isIpv4Address provider.ipv4.router)
    || !(isIpv4Address provider.ipv4.clientAddress)
    || !(isIpv4Address provider.ipv4.rangeStart)
    || !(isIpv4Address provider.ipv4.rangeEnd) then
      failInventory "${path}.provider.ipv4"
      "router, clientAddress, rangeStart, and rangeEnd must be IPv4 literals"
    else if !(isIpv6Address provider.ipv6.router) then
      failInventory "${path}.provider.ipv6.router" "must be an IPv6 literal"
    else if root.zone != "." then
      failInventory "${path}.root.zone" "must be the DNS root zone"
    else if delegation.zone == "." || !(lib.hasSuffix "." delegation.zone) then
      failInventory "${path}.delegation.zone"
      "must be an absolute delegated zone distinct from root"
    else if root.nameServer == delegation.nameServer then
      failInventory "${path}.delegation.nameServer"
      "must differ from the root name server"
    else if !(lib.hasSuffix delegation.zone terminal.name) then
      failInventory "${path}.terminal.name" "must be inside the delegated zone"
    else if trust.mode != "insecure-controlled-root" then
      failInventory "${path}.trust.mode"
      "must be insecure-controlled-root for this harness-only unsigned hierarchy"
    else {
      inherit kind scope traceId selectedUplink alternateUplinks provider root
        delegation terminal trust;
    };
}
