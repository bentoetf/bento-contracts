// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {BoxRegistry} from "../src/BoxRegistry.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {BoxNavOracle} from "../src/periphery/BoxNavOracle.sol";

/// @notice Fork test: BoxNavOracle reports live MAG7 NAV as a Chainlink-style feed.
contract BoxNavOracleForkTest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant SUSHI_ROUTER = 0x9A55D3d0c0f09859c7869510f53eD0a30B340766;
    address constant V4_UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant PONS_TOKEN = 0xcDd50D73B45085D71Cb05e2ca238d12C3Bd7bEBD;

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

    function testNavOracleReportsLiveNav() external {
        vm.createSelectFork("robinhood");

        address deployer = makeAddr("deployer");
        address safe = makeAddr("safe");
        vm.deal(deployer, 10 ether);

        vm.startPrank(deployer);
        address[] memory props = new address[](1);
        props[0] = safe;
        TimelockController timelock = new TimelockController(0, props, props, safe);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = PONS_TOKEN;
        FeeCollector collector = new FeeCollector(address(timelock), address(0), PONS_TOKEN, SUSHI_ROUTER, path);
        BoxRegistry registry = new BoxRegistry(deployer);
        UniswapV4Adapter adapter = new UniswapV4Adapter(V4_UNIVERSAL_ROUTER, V4_QUOTER, PERMIT2, USDG, deployer);
        BoxEngine engine =
            new BoxEngine(address(timelock), address(registry), address(collector), PONS_TOKEN, ETH_USD_FEED);
        registry.setRegistrar(address(engine));
        for (uint256 i; i < 7; ++i) {
            adapter.setUSDGRoute(STOCKS[i], _ethUsdPool(), _usdStockPool(STOCKS[i]));
        }
        vm.stopPrank();

        _tlExec(timelock, safe, address(collector), abi.encodeCall(FeeCollector.setEngine, (address(engine))));
        _tlExec(
            timelock,
            safe,
            address(engine),
            abi.encodeCall(
                BoxEngine.createBox,
                ("MAG7 Bento Box", "MAG7", _mag7Components(address(adapter)), 30, 30, uint128(15 ether), "")
            )
        );

        // constructor rejects a nonexistent box
        vm.expectRevert(BoxNavOracle.BoxMissing.selector);
        new BoxNavOracle(address(engine), 99);

        BoxNavOracle oracle = new BoxNavOracle(address(engine), 1);
        assertEq(oracle.decimals(), 8, "decimals");

        // mint so vault holds real backing and NAV is meaningful
        address user = makeAddr("user");
        vm.deal(user, 1 ether);
        vm.prank(user);
        engine.mint{value: 0.2 ether}(1, 0, new uint256[](7));

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = oracle.latestRoundData();
        assertEq(roundId, 1, "roundId");
        assertEq(answeredInRound, 1, "answeredInRound");
        assertEq(updatedAt, block.timestamp, "updatedAt");
        // MAG7 NAV should be near $100/box (allow wide band for market moves)
        assertGt(answer, 50e8, "nav lower bound");
        assertLt(answer, 200e8, "nav upper bound");
        // matches engine view exactly at 8 decimals
        assertEq(uint256(answer), engine.navUsdPerBox(1) / 1e10, "matches engine");
        emit log_named_int("MAG7 NAV usd (8 dec)", answer);
    }

    function _tlExec(TimelockController tl, address safe, address target, bytes memory data) internal {
        bytes32 salt = keccak256(data);
        uint256 delay = tl.getMinDelay();
        vm.prank(safe);
        tl.schedule(target, 0, data, bytes32(0), salt, delay);
        vm.prank(safe);
        tl.execute(target, 0, data, bytes32(0), salt);
    }

    function _mag7Components(address adapter_) internal view returns (BoxEngine.Component[] memory comps) {
        comps = new BoxEngine.Component[](7);
        uint16[7] memory weights = [uint16(1428), 1428, 1428, 1428, 1428, 1428, 1432];
        for (uint256 i; i < 7; ++i) {
            address[] memory p = new address[](2);
            p[0] = address(0);
            p[1] = STOCKS[i];
            comps[i] = BoxEngine.Component({
                token: STOCKS[i], weightBps: weights[i], router: adapter_, path: p, feed: FEEDS[i]
            });
        }
    }

    function _ethUsdPool() internal pure returns (UniswapV4Adapter.PoolKey memory p) {
        p = UniswapV4Adapter.PoolKey({
            currency0: address(0), currency1: USDG, fee: 460, tickSpacing: 9, hooks: address(0)
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
