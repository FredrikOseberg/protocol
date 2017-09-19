const ErrorLib                = artifacts.require("./lib/ErrorLib.sol");
const Bytes32Lib              = artifacts.require("./lib/Bytes32Lib.sol");
const Uint8Lib                = artifacts.require("./lib/Uint8Lib.sol");
const UintLib                 = artifacts.require("./lib/UintLib.sol");
const DummyToken              = artifacts.require("./test/DummyToken.sol");
const TestLrcToken            = artifacts.require("./test/TestLrcToken.sol");
const TokenRegistry           = artifacts.require("./TokenRegistry.sol");
const RinghashRegistry        = artifacts.require("./RinghashRegistry.sol");
const LoopringProtocolImpl    = artifacts.require("./LoopringProtocolImpl.sol");

module.exports = function(deployer: any, network: string, accounts: string[]) {

  if (network == 'live') {

  } else {
    deployer.then( async (accounts: string[]) => {
      await deployer.deploy(ErrorLib);
      await deployer.deploy(Bytes32Lib);
      await deployer.deploy(Uint8Lib);
      await deployer.deploy(UintLib);

      deployer.link(Bytes32Lib, RinghashRegistry);
      deployer.link(ErrorLib, RinghashRegistry);
      deployer.link(Uint8Lib, RinghashRegistry);

      await deployer.deploy(DummyToken, "DummyToken", "DUM", 18, 1e26);
      await deployer.deploy(TestLrcToken, "TestLrcToken", "TLRC", 18, 1e27);
      await deployer.deploy(RinghashRegistry, 10000);
      await deployer.deploy(TokenRegistry);

      deployer.link(ErrorLib, LoopringProtocolImpl);
      deployer.link(UintLib, LoopringProtocolImpl);

      await deployer.deploy(
        LoopringProtocolImpl,
        TestLrcToken.address,
        TokenRegistry.address,
        RinghashRegistry.address,
        5,
        2);
    });



    // }).then(() => {
    //   return
    // }).then(() => {
    //   return deployer.deploy(TestLrcToken, "TestLrcToken", "TLRC", 18, 1e27);
    // }).then(() => {
    //   return deployer.deploy(TokenRegistry);
    // }).then(() => {
    //   deployer.link(Bytes32Lib, RinghashRegistry);
    //   deployer.link(ErrorLib, RinghashRegistry);
    //   deployer.link(Uint8Lib, RinghashRegistry);
    //   return deployer.deploy(RinghashRegistry, 10000);
    // }).then(() => {
    //   deployer.link(ErrorLib, LoopringProtocolImpl);
    //   deployer.link(UintLib, LoopringProtocolImpl);
    //   return deployer.deploy(
    //     LoopringProtocolImpl,
    //     TestLrcToken.address,
    //     TokenRegistry.address,
    //     RinghashRegistry.address,
    //     5,
    //     2);
    // });
  }
};
