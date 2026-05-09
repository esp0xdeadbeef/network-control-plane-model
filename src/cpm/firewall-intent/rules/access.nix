{ common }:

localInterfaces: transitInterfaces:
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
