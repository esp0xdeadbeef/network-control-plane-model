{ common }:

{
  localInterfaces,
  transitInterfaces,
  runtimeOriginSourcePrefixes ? [ ],
}:
builtins.concatLists (
  builtins.map
    (localIface:
    builtins.concatLists (
      builtins.map
        (transitIface: common.selectorPairRule localIface transitIface)
        transitInterfaces
    ))
    localInterfaces
)
++ common.runtimeOriginDefaultForwardRules runtimeOriginSourcePrefixes transitInterfaces
