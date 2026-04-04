{ lib }:

let
  contract = import ../../lib/contract.nix { inherit lib; };

  requireRoutes = path: value:
    let
      routes = contract.requireAttrs "${path}.routes" value;
      ipv4 = contract.requireList "${path}.routes.ipv4" (routes.ipv4 or null);
      ipv6 = contract.requireList "${path}.routes.ipv6" (routes.ipv6 or null);
    in
    {
      inherit ipv4 ipv6;
    };

  logicalKey = logical:
    "${logical.enterprise}|${logical.site}|${logical.name}";

  makeWarning = key: message: context: {
    inherit key message context;
  };

  warningIf = condition: warning:
    if condition then
      [ warning ]
    else
      [ ];

  aggregateWarnings = warnings:
    let
      folded =
        builtins.foldl'
          (acc: warning:
            let
              key = warning.key;
              contextKey = contract.renderValue warning.context;
              existing =
                if contract.hasAttr key acc.byKey then
                  acc.byKey.${key}
                else
                  null;
            in
            if existing == null then
              {
                order = acc.order ++ [ key ];
                byKey =
                  acc.byKey
                  // {
                    ${key} = {
                      key = key;
                      message = warning.message;
                      occurrences = 1;
                      contextsByRender = {
                        ${contextKey} = warning.context;
                      };
                    };
                  };
              }
            else
              {
                order = acc.order;
                byKey =
                  acc.byKey
                  // {
                    ${key} =
                      existing
                      // {
                        occurrences = existing.occurrences + 1;
                        contextsByRender =
                          if contract.hasAttr contextKey existing.contextsByRender then
                            existing.contextsByRender
                          else
                            existing.contextsByRender
                            // {
                              ${contextKey} = warning.context;
                            };
                      };
                  };
              })
          {
            order = [ ];
            byKey = { };
          }
          warnings;
    in
    builtins.map
      (key:
        let
          warning = folded.byKey.${key};
        in
        {
          key = key;
          message = warning.message;
          occurrences = warning.occurrences;
          contexts =
            builtins.map
              (contextKey: warning.contextsByRender.${contextKey})
              (contract.sortedNames warning.contextsByRender);
        })
      folded.order;

  emitWarnings = warnings: value:
    builtins.seq
      (contract.forceAll (
        builtins.map
          (warning:
            let
              contextPayload =
                if warning.occurrences <= 1 then
                  builtins.elemAt warning.contexts 0
                else
                  {
                    occurrenceCount = warning.occurrences;
                    contexts = warning.contexts;
                  };
            in
            builtins.trace
              "migration warning: ${warning.message}\n--- offending input context ---\n${contract.renderValue contextPayload}"
              true)
          warnings
      ))
      value;
in
contract // {
  inherit
    aggregateWarnings
    emitWarnings
    logicalKey
    makeWarning
    requireRoutes
    warningIf;
}
