// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {BoxRegistry} from "../src/BoxRegistry.sol";
import {BentoToken} from "../src/BentoToken.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

/// @notice Phase 1G deploy-prep script for Robinhood mainnet.
/// @dev No contract changes: BoxEngine/FeeCollector/Bento admin are immutable, so final admin must be the timelock at construction.
///      This script deploys missing base contracts, configures deployer-owned one-time pieces, writes Safe->Timelock calldata,
///      and verifies every deploy-time config value it can verify before delayed timelock execution.
contract Phase1GDeploy is Script {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant SUSHI_ROUTER = 0x9A55D3d0c0f09859c7869510f53eD0a30B340766;
    address constant V4_UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant NATIVE_ETH = address(0);
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    uint256 constant TIMELOCK_DELAY = 24 hours;
    uint256 constant MAG7_BOX_ID = 1;

    address[7] STOCKS = [
        address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC),
        address(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9),
        address(0xe93237C50D904957Cf27E7B1133b510C669c2e74),
        address(0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3),
        address(0x12f190a9F9d7D37a250758b26824B97CE941bF54),
        address(0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35),
        address(0x322F0929c4625eD5bAd873c95208D54E1c003b2d)
    ];

    address[7] FEEDS = [
        address(0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15),
        address(0x6B22A786bAa607d76728168703a39Ea9C99f2cD0),
        address(0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E),
        address(0xF6f373a037c30F0e5010d854385cA89185AE638b),
        address(0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C),
        address(0x7C38C00C30BEe9378381E7B6135d7283356D71b1),
        address(0x4A1166a659A55625345e9515b32adECea5547C38)
    ];

    struct Deployed {
        address deployer;
        address safe;
        address devWallet;
        address lpSeedingWallet;
        address timelock;
        address bento;
        address collector;
        address registry;
        address adapter;
        address engine;
    }

    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        Deployed memory d;
        d.deployer = vm.addr(key);
        d.safe = vm.envAddress("SAFE_ADDRESS");
        d.devWallet = vm.envAddress("DEV_WALLET");
        d.lpSeedingWallet = vm.envAddress("LP_SEEDING_WALLET");
        d.timelock = vm.envOr("TIMELOCK_ADDRESS", address(0));
        d.bento = vm.envOr("BENTO_ADDRESS", address(0));
        d.collector = vm.envOr("FEE_COLLECTOR_ADDRESS", address(0));
        d.registry = vm.envOr("BOX_REGISTRY_ADDRESS", address(0));
        d.adapter = vm.envOr("V4_ADAPTER_ADDRESS", address(0));
        d.engine = vm.envOr("BOX_ENGINE_ADDRESS", address(0));
        address ethUsdFeed = vm.envOr("ETH_USD_FEED", ETH_USD_FEED);

        vm.startBroadcast(key);
        if (d.timelock == address(0)) d.timelock = address(_deployTimelock(d.safe));
        if (d.bento == address(0)) d.bento = address(new BentoToken(d.deployer, d.timelock, d.devWallet));

        address[] memory buybackPath = new address[](2);
        buybackPath[0] = WETH;
        buybackPath[1] = d.bento;
        if (d.collector == address(0)) {
            d.collector = address(new FeeCollector(d.timelock, address(0), d.bento, SUSHI_ROUTER, buybackPath));
        }
        if (d.registry == address(0)) d.registry = address(new BoxRegistry(d.deployer));
        if (d.adapter == address(0)) {
            d.adapter = address(new UniswapV4Adapter(V4_UNIVERSAL_ROUTER, V4_QUOTER, PERMIT2, USDG, d.deployer));
        }
        if (d.engine == address(0)) {
            d.engine = address(new BoxEngine(d.timelock, d.registry, d.collector, d.bento, ethUsdFeed));
        }

        if (BoxRegistry(d.registry).registrar() == address(0)) BoxRegistry(d.registry).setRegistrar(d.engine);
        _ensureRoutesAndTransferAdapter(d.adapter, d.timelock, d.deployer);
        vm.stopBroadcast();

        _writeTimelockCalldata(d);
        _verifyDeployTimeConfig(d, ethUsdFeed);
        _log(d);
    }

    function _deployTimelock(address safe) internal returns (TimelockController timelock) {
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, safe);
    }

    function _ensureRoutesAndTransferAdapter(address adapter_, address timelock, address deployer) internal {
        if (Ownable(adapter_).owner() == deployer) {
            for (uint256 i; i < 7; ++i) {
                UniswapV4Adapter(payable(adapter_)).setUSDGRoute(STOCKS[i], _ethUsdPool(), _usdStockPool(STOCKS[i]));
            }
            UniswapV4Adapter(payable(adapter_)).transferOwnership(timelock);
        }
    }

    function _writeTimelockCalldata(Deployed memory d) internal {
        BoxEngine.Component[] memory comps = _mag7Components(d.adapter);
        bytes memory createMag7 =
            abi.encodeCall(BoxEngine.createBox, ("MAG7 Bento Box", "MAG7", comps, 30, 30, uint128(15 ether), ""));
        bytes memory setEngine = abi.encodeCall(FeeCollector.setEngine, (d.engine));
        bytes memory setPerTxCap = abi.encodeCall(BoxEngine.setPerTxMintCap, (MAG7_BOX_ID, uint128(2 ether)));
        bytes memory exemptEngine = abi.encodeCall(BentoToken.setTaxExempt, (d.engine, true));
        bytes memory exemptCollector = abi.encodeCall(BentoToken.setTaxExempt, (d.collector, true));
        bytes memory exemptDead =
            abi.encodeCall(BentoToken.setTaxExempt, (FeeCollector(payable(d.collector)).DEAD(), true));
        bytes memory exemptLpSeeder = abi.encodeCall(BentoToken.setTaxExempt, (d.lpSeedingWallet, true));
        bytes memory taxedPairTemplate =
            abi.encodeCall(BentoToken.setTaxedPair, (address(0x1111111111111111111111111111111111111111), true));
        bytes memory exemptVaultTemplate =
            abi.encodeCall(BentoToken.setTaxExempt, (address(0x2222222222222222222222222222222222222222), true));

        vm.writeFile("out/phase1g-01-feeCollector-setEngine.calldata.txt", vm.toString(setEngine));
        vm.writeFile("out/phase1g-02-bento-exempt-engine.calldata.txt", vm.toString(exemptEngine));
        vm.writeFile("out/phase1g-03-bento-exempt-collector.calldata.txt", vm.toString(exemptCollector));
        vm.writeFile("out/phase1g-04-bento-exempt-dead.calldata.txt", vm.toString(exemptDead));
        vm.writeFile("out/phase1g-05-bento-exempt-lpSeeder.calldata.txt", vm.toString(exemptLpSeeder));
        vm.writeFile("out/phase1g-06-engine-createMag7.calldata.txt", vm.toString(createMag7));
        vm.writeFile("out/phase1g-07-engine-setMag7PerTxCap.calldata.txt", vm.toString(setPerTxCap));
        vm.writeFile("out/phase1g-template-bento-setTaxedPair-PLACEHOLDER.calldata.txt", vm.toString(taxedPairTemplate));
        vm.writeFile(
            "out/phase1g-template-bento-exemptVault-PLACEHOLDER.calldata.txt", vm.toString(exemptVaultTemplate)
        );
    }

    function _verifyDeployTimeConfig(Deployed memory d, address ethUsdFeed) internal view {
        require(BentoToken(d.bento).admin() == d.timelock, "BENTO_ADMIN");
        require(BentoToken(d.bento).devWallet() == d.devWallet, "BENTO_DEV");
        require(BentoToken(d.bento).taxBps() == 300, "BENTO_TAX");
        require(FeeCollector(payable(d.collector)).admin() == d.timelock, "COLLECTOR_ADMIN");
        require(FeeCollector(payable(d.collector)).bento() == d.bento, "COLLECTOR_BENTO");
        require(BoxEngine(payable(d.engine)).admin() == d.timelock, "ENGINE_ADMIN");
        require(BoxEngine(payable(d.engine)).registry() == d.registry, "ENGINE_REGISTRY");
        require(BoxEngine(payable(d.engine)).feeCollector() == d.collector, "ENGINE_COLLECTOR");
        require(BoxEngine(payable(d.engine)).bento() == d.bento, "ENGINE_BENTO");
        require(BoxEngine(payable(d.engine)).ethUsdFeed() == ethUsdFeed, "ENGINE_ETH_FEED");
        require(BoxRegistry(d.registry).registrar() == d.engine, "REGISTRY_REGISTRAR");
        require(Ownable(d.adapter).owner() == d.timelock, "ADAPTER_OWNER");
    }

    function _log(Deployed memory d) internal view {
        console2.log("deployer", d.deployer);
        console2.log("safe", d.safe);
        console2.log("timelock", d.timelock);
        console2.log("bento", d.bento);
        console2.log("feeCollector", d.collector);
        console2.log("boxRegistry", d.registry);
        console2.log("v4Adapter", d.adapter);
        console2.log("boxEngine", d.engine);
        console2.log("feeCollector.engine pending timelock", FeeCollector(payable(d.collector)).engine());
        console2.log("next timelock ops", "out/phase1g-*.calldata.txt");
    }

    function _mag7Components(address adapter_) internal view returns (BoxEngine.Component[] memory comps) {
        comps = new BoxEngine.Component[](7);
        uint16[7] memory weights = [uint16(1428), 1428, 1428, 1428, 1428, 1428, 1432];
        for (uint256 i; i < 7; ++i) {
            address[] memory path = new address[](2);
            path[0] = NATIVE_ETH;
            path[1] = STOCKS[i];
            comps[i] = BoxEngine.Component({
                token: STOCKS[i], weightBps: weights[i], router: adapter_, path: path, feed: FEEDS[i]
            });
        }
    }

    function _ethUsdPool() internal pure returns (UniswapV4Adapter.PoolKey memory p) {
        p = UniswapV4Adapter.PoolKey({
            currency0: NATIVE_ETH, currency1: USDG, fee: 460, tickSpacing: 9, hooks: address(0)
        });
    }

    function _usdStockPool(address token) internal pure returns (UniswapV4Adapter.PoolKey memory p) {
        p = UniswapV4Adapter.PoolKey({
            currency0: token < USDG ? token : USDG,
            currency1: token < USDG ? USDG : token,
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
    }
}
