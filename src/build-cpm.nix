{ lib }:

{ enterprise, inventory ? {} }:

let
  invariants = import ../invariants/default.nix { inherit lib; };

  requireAttrs = path: value:
    if builtins.isAttrs value then value
    else throw "missing required ${path} attribute set";

  requireString = path: value:
    if builtins.isString value && value != "" then value
    else throw "missing required ${path} non-empty string";

  optionalAttrs = value:
    if value == null then { }
    else if builtins.isAttrs value then value
    else throw "expected attribute set, got ${builtins.typeOf value}";

  attrNames = attrs:
    if builtins.isAttrs attrs then lib.attrNamesSorted attrs else [ ];

  normalizeOverlay = site:
    let
      transport =
        if site ? transport then requireAttrs "site.transport" site.transport else {};
      overlays = transport.overlays or {};
    in
    if builtins.isAttrs overlays || builtins.isList overlays then overlays
    else throw "site.transport.overlays must be an attribute set or list";

  normalizeTransit = site:
    let
      transit =
        if site ? transit then site.transit
        else throw "missing explicit site.transit with adjacencies and ordering";
    in
    if invariants.hasExplicitTransit transit then transit
    else throw "missing explicit site.transit with adjacencies and ordering";

  normalizeSite = site:
    let siteAttrs = requireAttrs "site" site;
    in {
      transit = normalizeTransit siteAttrs;
      overlay = normalizeOverlay siteAttrs;
    };

  normalizeEnterpriseSites = enterpriseName: ent:
    let
      entAttrs = requireAttrs "enterprise.${enterpriseName}" ent;
      siteRoot =
        if entAttrs ? site then
          requireAttrs "enterprise.${enterpriseName}.site" entAttrs.site
        else
          throw "missing required enterprise.${enterpriseName}.site attribute set";
    in
    lib.mapAttrsSorted (_: site: normalizeSite site) siteRoot;

  enterpriseAttrs =
    if builtins.isAttrs enterprise then enterprise
    else throw "missing required forwardingModel.enterprise attribute set";

  inputValidation = invariants.validateEnterpriseInputs enterpriseAttrs;

  cpmData =
    lib.mapAttrsSorted
      (enterpriseName: ent: normalizeEnterpriseSites enterpriseName ent)
      enterpriseAttrs;

  cpmValidation = invariants.validateCPMData cpmData;

  inventoryRoot = optionalAttrs inventory;
  realization = optionalAttrs (inventoryRoot.realization or null);
  nodes = optionalAttrs (realization.nodes or null);

  mkLogicalNode = nodePath: nodeName: node:
    if node ? logicalNode then
      let
        logicalNode = requireAttrs "${nodePath}.logicalNode" node.logicalNode;
      in
      {
        enterprise = requireString "${nodePath}.logicalNode.enterprise" (logicalNode.enterprise or null);
        site = requireString "${nodePath}.logicalNode.site" (logicalNode.site or null);
        name = requireString "${nodePath}.logicalNode.name" (logicalNode.name or null);
      }
    else
      {
        enterprise = "";
        site = "";
        name = nodeName;
      };

  mkInterfaces = nodePath: ports:
    if ports == {} then
      {}
    else
      builtins.listToAttrs (
        builtins.map
          (portName:
            let
              portPath = "${nodePath}.ports.${portName}";
              port = requireAttrs portPath ports.${portName};
              iface = requireAttrs "${portPath}.interface" port.interface;
              ifName = requireString "${portPath}.interface.name" (iface.name or null);
            in
            {
              name = ifName;
              value = {
                runtimeInterface = ifName;
                logicalInterfaces = [];
                link = port.link or null;
                attachment = port.attach or null;
              };
            }
          )
          (attrNames ports)
      );

  mkRuntimePorts = nodePath: ports:
    if ports == {} then
      []
    else
      builtins.map
        (portName:
          let
            portPath = "${nodePath}.ports.${portName}";
            port = requireAttrs portPath ports.${portName};
            iface = requireAttrs "${portPath}.interface" port.interface;
            ifName = requireString "${portPath}.interface.name" (iface.name or null);
          in
          {
            runtimePort = portName;
            runtimeInterface = ifName;
          }
        )
        (attrNames ports);

  runtimeTargets =
    if nodes == {} then
      {}
    else
      builtins.listToAttrs (
        builtins.map
          (nodeName:
            let
              nodePath = "inventory.realization.nodes.${nodeName}";
              node = requireAttrs nodePath nodes.${nodeName};
              ports = requireAttrs "${nodePath}.ports" (node.ports or null);
              logicalNode = mkLogicalNode nodePath nodeName node;
            in
            {
              name = nodeName;
              value = {
                logicalNode = logicalNode;
                effectiveRuntimeRealization = {
                  interfaces = mkInterfaces nodePath ports;
                  runtimePorts = mkRuntimePorts nodePath ports;
                };
              };
            }
          )
          (attrNames nodes)
      );

in
builtins.seq inputValidation (
  builtins.seq cpmValidation {
    version = 1;
    source = "nix";
    data = cpmData;
    runtime = { targets = runtimeTargets; };
  }
)
