{ lib
, enterpriseName
, siteName
, siteId
, siteAttrs
, inventory
,
}:

let
  requirement = siteAttrs.hostManagement or null;
  required = requirement != null && (requirement.required or false) == true;
  logicalInterface = if requirement == null then null else requirement.interface or null;
  purpose = if requirement == null then null else requirement.purpose or null;

  deploymentHosts =
    if
      inventory ? deployment
      && builtins.isAttrs inventory.deployment
      && inventory.deployment ? hosts
      && builtins.isAttrs inventory.deployment.hosts
    then
      inventory.deployment.hosts
    else
      { };

  sortedHostNames = lib.sort builtins.lessThan (builtins.attrNames deploymentHosts);
  bindingFor = hostName:
    let host = deploymentHosts.${hostName};
    in if builtins.isAttrs (host.hostManagement or null) then host.hostManagement else null;
  matchingHostNames = builtins.filter
    (hostName:
      let binding = bindingFor hostName;
      in binding != null && (binding.logicalInterface or null) == logicalInterface)
    sortedHostNames;

  mkDiagnostic = code: reason: message: {
    inherit code reason message;
    severity = "warning";
    sourceLayer = "inventory";
    traceId = "FS-982-HDS-010-SDS-010-SMS-120";
    scope = {
      kind = "site";
      enterprise = enterpriseName;
      site = siteName;
      inherit siteId;
    };
    logicalInterface = logicalInterface;
  };

  cardinalityDiagnostics =
    if !required then
      [ ]
    else if matchingHostNames == [ ] then
      [
        (mkDiagnostic
          "HOST_MANAGEMENT_BINDING_MISSING"
          "required-intent-has-no-explicit-inventory-binding"
          "Required host management has no explicit deployment-host binding; renderer output is suppressed until inventory declares hostManagement.logicalInterface, link, and addressAcquisition")
      ]
    else if builtins.length matchingHostNames > 1 then
      [
        (mkDiagnostic
          "HOST_MANAGEMENT_BINDING_AMBIGUOUS"
          "multiple-explicit-inventory-bindings"
          "Required host management resolves to multiple deployment-host bindings; renderer output is suppressed")
      ]
    else
      [ ];

  selectedHostName =
    if required && builtins.length matchingHostNames == 1 then builtins.head matchingHostNames else null;
  selectedBinding = if selectedHostName == null then null else bindingFor selectedHostName;
  link = if selectedBinding == null || !(builtins.isAttrs (selectedBinding.link or null)) then null else selectedBinding.link;
  acquisition =
    if selectedBinding == null || !(builtins.isAttrs (selectedBinding.addressAcquisition or null)) then
      null
    else
      selectedBinding.addressAcquisition;

  linkValid =
    link != null
    && builtins.elem (link.kind or null) [ "bridge" "interface" ]
    && builtins.isString (link.name or null)
    && link.name != ""
    && (link.containerOnly or false) == false;
  acquisitionValid =
    acquisition != null
    && (acquisition.ipv4 or null) == "dhcp"
    && (acquisition.ipv6 or null) == "disabled"
    && (acquisition.acceptRA or false) == false
    && (acquisition.useDns or null) == false;

  bindingDiagnostics =
    if selectedBinding == null then
      [ ]
    else
      (lib.optional (!linkValid) (
        mkDiagnostic
          "HOST_MANAGEMENT_BINDING_INVALID"
          "link-is-missing-ambiguous-or-container-only"
          "Host-management binding must name one non-container bridge or interface; renderer output is suppressed"
      ))
      ++ (lib.optional (!acquisitionValid) (
        mkDiagnostic
          "HOST_MANAGEMENT_AUTHORITY_WIDENED"
          "address-acquisition-policy-is-incomplete-or-too-broad"
          "Host-management acquisition must be DHCPv4-only with IPv6, RA, DNS replacement, and default-route acquisition disabled; renderer output is suppressed"
      ));

  diagnostics = cardinalityDiagnostics ++ bindingDiagnostics;
  runtimeTarget =
    if !required then
      null
    else if selectedBinding != null && diagnostics == [ ] then
      {
        kind = "host-management-runtime-target";
        schemaVersion = 1;
        deploymentHost = selectedHostName;
        inherit logicalInterface purpose;
        managementOnly = true;
        link = {
          kind = link.kind;
          name = link.name;
        };
        addressAcquisition = {
          ipv4 = "dhcp";
          ipv6 = "disabled";
          acceptRA = false;
          useDns = false;
          defaultRoute = true;
        };
        provenance = {
          intentPath = "forwardingModel.enterprise.${enterpriseName}.site.${siteName}.hostManagement";
          inventoryPath = "inventory.deployment.hosts.${selectedHostName}.hostManagement";
          authority = "network-control-plane-model";
        };
      }
    else
      null;
in
if requirement == null then
  null
else
  {
    validated = diagnostics == [ ];
    requirement = {
      inherit required logicalInterface purpose;
      managementOnly = requirement.managementOnly or true;
    };
    inherit diagnostics runtimeTarget;
  }
