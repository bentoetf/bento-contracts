// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {BoxRegistry} from "../src/BoxRegistry.sol";
import {BentoToken} from "../src/BentoToken.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

contract Deploy is Script {
    address constant WETH = address(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73);
    address constant SUSHI_ROUTER = address(0x9A55D3d0c0f09859c7869510f53eD0a30B340766);
    address constant V4_UNIVERSAL_ROUTER = address(0x8876789976dEcBfCbBbe364623C63652db8C0904);
    address constant V4_QUOTER = address(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    address constant PERMIT2 = address(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant USDG = address(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant NATIVE_ETH = address(0);
    address constant ETH_USD_FEED = address(0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9);

    address[7] STOCKS = [
        address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC), // NVDA
        address(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9), // AAPL
        address(0xe93237C50D904957Cf27E7B1133b510C669c2e74), // MSFT
        address(0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3), // GOOGL
        address(0x12f190a9F9d7D37a250758b26824B97CE941bF54), // AMZN
        address(0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35), // META
        address(0x322F0929c4625eD5bAd873c95208D54E1c003b2d) // TSLA
    ];

    address[7] FEEDS = [
        address(0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15), // NVDA/USD
        address(0x6B22A786bAa607d76728168703a39Ea9C99f2cD0), // AAPL/USD
        address(0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E), // MSFT/USD
        address(0xF6f373a037c30F0e5010d854385cA89185AE638b), // GOOGL/USD
        address(0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C), // AMZN/USD
        address(0x7C38C00C30BEe9378381E7B6135d7283356D71b1), // META/USD
        address(0x4A1166a659A55625345e9515b32adECea5547C38) // TSLA/USD
    ];

    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address safe = vm.envAddress("SAFE_ADDRESS");
        address devWallet = vm.envAddress("DEV_WALLET");
        address lpSeedingWallet = vm.envAddress("LP_SEEDING_WALLET");
        address ethUsdFeed = vm.envOr("ETH_USD_FEED", ETH_USD_FEED);

        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;
        address[] memory buybackPath = new address[](2);
        buybackPath[0] = WETH;

        vm.startBroadcast(key);
        TimelockController timelock = new TimelockController(24 hours, proposers, executors, safe);
        BentoToken bento = new BentoToken(msg.sender, address(timelock), devWallet);
        buybackPath[1] = address(bento);
        FeeCollector collector =
            new FeeCollector(address(timelock), address(0), address(bento), SUSHI_ROUTER, buybackPath);
        BoxRegistry registry = new BoxRegistry(msg.sender);
        UniswapV4Adapter adapter = new UniswapV4Adapter(V4_UNIVERSAL_ROUTER, V4_QUOTER, PERMIT2, USDG, msg.sender);
        BoxEngine engine =
            new BoxEngine(address(timelock), address(registry), address(collector), address(bento), ethUsdFeed);
        registry.setRegistrar(address(engine));
        collector.setEngine(address(engine));

        BoxEngine.Component[] memory comps = new BoxEngine.Component[](7);
        uint16[7] memory weights = [uint16(1428), 1428, 1428, 1428, 1428, 1428, 1432];
        for (uint256 i; i < 7; ++i) {
            // Adapter route sentinel: path[0] == address(0), path[last] == token.
            address[] memory path = new address[](2);
            path[0] = NATIVE_ETH;
            path[1] = STOCKS[i];
            comps[i] = BoxEngine.Component({
                token: STOCKS[i], weightBps: weights[i], router: address(adapter), path: path, feed: FEEDS[i]
            });
        }

        // Submit these calldata payloads through Safe -> Timelock after deploy.
        bytes memory createMag7Calldata =
            abi.encodeCall(BoxEngine.createBox, ("MAG7 Bento Box", "MAG7", comps, 30, 30, uint128(15 ether), ""));
        bytes memory setMag7PerTxCapCalldata = abi.encodeCall(BoxEngine.setPerTxMintCap, (uint256(1), uint128(2 ether)));
        bytes memory setTaxedPairTemplate =
            abi.encodeCall(BentoToken.setTaxedPair, (address(0x1111111111111111111111111111111111111111), true));
        bytes memory exemptEngineCalldata = abi.encodeCall(BentoToken.setTaxExempt, (address(engine), true));
        bytes memory exemptCollectorCalldata = abi.encodeCall(BentoToken.setTaxExempt, (address(collector), true));
        bytes memory exemptDeadCalldata = abi.encodeCall(BentoToken.setTaxExempt, (collector.DEAD(), true));
        bytes memory exemptLpSeederCalldata = abi.encodeCall(BentoToken.setTaxExempt, (lpSeedingWallet, true));
        bytes memory exemptVaultTemplate =
            abi.encodeCall(BentoToken.setTaxExempt, (address(0x2222222222222222222222222222222222222222), true));
        vm.writeFile("out/createMag7.calldata.txt", vm.toString(createMag7Calldata));
        vm.writeFile("out/setMag7PerTxMintCap.calldata.txt", vm.toString(setMag7PerTxCapCalldata));
        vm.writeFile("out/setBentoTaxedPair-PLACEHOLDER.calldata.txt", vm.toString(setTaxedPairTemplate));
        vm.writeFile("out/setBentoTaxExempt-engine.calldata.txt", vm.toString(exemptEngineCalldata));
        vm.writeFile("out/setBentoTaxExempt-feeCollector.calldata.txt", vm.toString(exemptCollectorCalldata));
        vm.writeFile("out/setBentoTaxExempt-dead.calldata.txt", vm.toString(exemptDeadCalldata));
        vm.writeFile("out/setBentoTaxExempt-lpSeeder.calldata.txt", vm.toString(exemptLpSeederCalldata));
        vm.writeFile("out/setBentoTaxExempt-vault-PLACEHOLDER.calldata.txt", vm.toString(exemptVaultTemplate));

        for (uint256 i; i < 7; ++i) {
            bytes memory routeCalldata =
                abi.encodeCall(UniswapV4Adapter.setUSDGRoute, (STOCKS[i], _ethUsdPool(), _usdStockPool(STOCKS[i])));
            vm.writeFile(
                string.concat("out/setUSDGRoute-", vm.toString(i), ".calldata.txt"), vm.toString(routeCalldata)
            );
            adapter.setUSDGRoute(STOCKS[i], _ethUsdPool(), _usdStockPool(STOCKS[i]));
        }
        adapter.transferOwnership(address(timelock));
        vm.stopBroadcast();
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
