{ helpers, common, sitePath, siteAttrs, inventoryAttrs, siteName }:

let
  inherit (helpers)
    requireAttrs
    requireString
    sortedNames
    ;
  inherit (common)
    attrsOrEmpty
    failInventory
    ;

  upstreamIntentRoot = attrsOrEmpty (siteAttrs.upstreamEmulation or null);
  emulatedIspIntent =
    if builtins.isAttrs (upstreamIntentRoot.emulatedIsp or null) then
      upstreamIntentRoot.emulatedIsp
    else
      null;

  scenariosRoot =
    let
      cp = attrsOrEmpty (inventoryAttrs.controlPlane or null);
      upstream = attrsOrEmpty (cp.upstreamEmulation or null);
    in
    attrsOrEmpty (upstream.scenarios or null);

  scenarioNamesForSite =
    builtins.filter
      (scenarioName:
        let
          scenario = scenariosRoot.${scenarioName};
        in
        builtins.isAttrs scenario
        && (scenario.site or null) == siteName)
      (sortedNames scenariosRoot);

  requireScenarioString = scenarioName: suffix: value:
    requireString "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.${suffix}" value;

  normalizePppoe = scenarioName: scenario:
    let
      scenarioId = requireScenarioString scenarioName "scenarioId" (scenario.scenarioId or null);
      gampId = requireScenarioString scenarioName "gampId" (scenario.gampId or null);
      backend = requireScenarioString scenarioName "backend" (scenario.backend or null);
      host = requireScenarioString scenarioName "host" (scenario.host or null);
      substrate = requireAttrs "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.substrate" (scenario.substrate or null);
      ispHandoff = requireAttrs "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.substrate.ispHandoff" (substrate.ispHandoff or null);
      accessConcentrator = requireAttrs "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.accessConcentrator" (scenario.accessConcentrator or null);
      credentials = requireAttrs "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.credentials" (scenario.credentials or null);
      intentRef = requireAttrs "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.intentRef" (scenario.intentRef or null);
      providerIntent = requireAttrs "${sitePath}.upstreamEmulation.emulatedIsp.provider" (emulatedIspIntent.provider or null);
      customerIntent = requireAttrs "${sitePath}.upstreamEmulation.emulatedIsp.customer" (emulatedIspIntent.customer or null);
      publicFacing = requireAttrs "${sitePath}.upstreamEmulation.emulatedIsp.publicFacing" (emulatedIspIntent.publicFacing or null);
      ipv4 = requireAttrs "${sitePath}.upstreamEmulation.emulatedIsp.publicFacing.ipv4" (publicFacing.ipv4 or null);
      ipv6 = requireAttrs "${sitePath}.upstreamEmulation.emulatedIsp.publicFacing.ipv6" (publicFacing.ipv6 or null);
      addressDelivery = requireAttrs "${sitePath}.upstreamEmulation.emulatedIsp.provider.addressDelivery" (providerIntent.addressDelivery or null);
      excludedDelivery = addressDelivery.excluded or [ ];
      handoff = requireString "${sitePath}.upstreamEmulation.emulatedIsp.provider.handoff" (providerIntent.handoff or null);
      _handoff =
        if handoff == "pppoe" then
          true
        else
          failInventory "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}" "only PPPoE upstream emulation is supported by this control-plane handoff";
      _scenario =
        if (emulatedIspIntent.scenarioId or null) == scenarioId then
          true
        else
          failInventory "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.scenarioId" "does not match ${sitePath}.upstreamEmulation.emulatedIsp.scenarioId";
    in
    builtins.seq _handoff (builtins.seq _scenario {
      inherit scenarioId gampId backend host;
      source = "inventory.controlPlane.upstreamEmulation.scenarios";
      intentSource = "${sitePath}.upstreamEmulation.emulatedIsp";
      mode = "pppoe";
      probeIntent = emulatedIspIntent.probeIntent or [ ];
      failureExpectation = emulatedIspIntent.failureExpectation or null;
      dns = attrsOrEmpty (emulatedIspIntent.dns or null);
      firewall = attrsOrEmpty (emulatedIspIntent.firewall or null);
      handoff = {
        kind = requireString "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.substrate.ispHandoff.kind" (ispHandoff.kind or null);
        bridge = requireString "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.substrate.ispHandoff.bridge" (ispHandoff.bridge or null);
        physical = ispHandoff.physical or false;
        mtu = substrate.mtu or 1492;
      };
      pppoe = {
        server = {
          side = requireString "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.accessConcentrator.side" (accessConcentrator.side or null);
          implementation = requireString "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.accessConcentrator.implementation" (accessConcentrator.implementation or null);
          node = requireString "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.accessConcentrator.node" (accessConcentrator.node or null);
          handoffBridge = requireString "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.substrate.ispHandoff.bridge" (ispHandoff.bridge or null);
          mtu = substrate.mtu or 1492;
          credentials = {
            labOnly = credentials.labOnly or false;
            usernameFile = requireString "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.credentials.usernameFile" (credentials.usernameFile or null);
            passwordFile = requireString "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.credentials.passwordFile" (credentials.passwordFile or null);
          };
          session = {
            ipv4Prefix = requireString "${sitePath}.upstreamEmulation.emulatedIsp.publicFacing.ipv4.sessionPrefix" (ipv4.sessionPrefix or null);
            providerAddress = requireString "${sitePath}.upstreamEmulation.emulatedIsp.publicFacing.ipv4.providerAddress" (ipv4.providerAddress or null);
            customerAddress = requireString "${sitePath}.upstreamEmulation.emulatedIsp.publicFacing.ipv4.customerAddress" (ipv4.customerAddress or null);
            delegatedAggregate = requireString "${sitePath}.upstreamEmulation.emulatedIsp.publicFacing.ipv6.delegatedAggregate" (ipv6.delegatedAggregate or null);
            childPrefixLength = ipv6.childPrefixLength or null;
          };
        };
        client = {
          coreNode = requireString "${sitePath}.upstreamEmulation.emulatedIsp.customer.coreNode" (customerIntent.coreNode or null);
          coreInterface = requireString "${sitePath}.upstreamEmulation.emulatedIsp.customer.coreInterface" (customerIntent.coreInterface or null);
          runtimeInterface = "ppp0";
          handoffBridge = requireString "inventory.controlPlane.upstreamEmulation.scenarios.${scenarioName}.substrate.ispHandoff.bridge" (ispHandoff.bridge or null);
          mtu = substrate.mtu or 1492;
          addressDelivery = {
            ipv4 = requireString "${sitePath}.upstreamEmulation.emulatedIsp.provider.addressDelivery.ipv4" (addressDelivery.ipv4 or null);
            ipv6 = requireString "${sitePath}.upstreamEmulation.emulatedIsp.provider.addressDelivery.ipv6" (addressDelivery.ipv6 or null);
            excluded = excludedDelivery;
            wanDhcpFallback = !(builtins.elem "wan-dhcp" excludedDelivery);
            wanSlaacFallback = !(builtins.elem "wan-slaac" excludedDelivery);
          };
        };
      };
    });

in
if emulatedIspIntent == null then
  { }
else
  {
    upstreamEmulation =
      builtins.listToAttrs (
        builtins.map
          (scenarioName: {
            name = scenarioName;
            value = normalizePppoe scenarioName scenariosRoot.${scenarioName};
          })
          scenarioNamesForSite
      );
  }
