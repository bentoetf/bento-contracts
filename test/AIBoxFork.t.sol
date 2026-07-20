// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {BoxRegistry} from "../src/BoxRegistry.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

/// @notice Fork test for the planned AI7 box (box #2): NVDA, AMD, TSM, MU,
///         PLTR, ORCL, CRWV. Verifies live feeds, V4 route liquidity, and a
///         mint/redeem round trip, including the post-launch flow where the
///         adapter is timelock-owned so new routes go through timelock ops.
contract AIBoxForkTest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant SUSHI_ROUTER = 0x9A55D3d0c0f09859c7869510f53eD0a30B340766;
    address constant V4_UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant PONS_TOKEN = 0xcDd50D73B45085D71Cb05e2ca238d12C3Bd7bEBD;

    // AI3 constituents: the AI names with real V4 USDG pool liquidity today
    // (TSM/PLTR/ORCL/CRWV only have dust/mispriced pools; add later as liq arrives).
    address[3] STOCKS = [
        address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC), // NVDA
        address(0x86923f96303D656E4aa86D9d42D1e57ad2023fdC), // AMD
        address(0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD)  // MU
    ];

    // Chainlink feeds from the official reference-data directory.
    address[3] FEEDS = [
        address(0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15), // NVDA/USD
        address(0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72), // AMD/USD
        address(0x425EEFdCf05ed6526C3cE61Af99429A228a6d596)  // MU/USD
    ];

    function testAIBoxMintRedeemRoundTrip() external {
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
        // launch state: adapter handed to timelock BEFORE the AI box exists,
        // so route additions must work via timelock ops like they will in prod
        adapter.transferOwnership(address(timelock));
        vm.stopPrank();

        _tlExec(timelock, safe, address(collector), abi.encodeCall(FeeCollector.setEngine, (address(engine))));

        // post-launch flow: add routes through the timelock.
        // Live pool reality (probed 2026-07-20): NVDA USDG fee=3000; AMD/MU USDG fee=10000.
        for (uint256 i; i < 3; ++i) {
            uint24 fee = i == 0 ? 3000 : 10000;
            int24 tick = i == 0 ? int24(60) : int24(200);
            _tlExec(
                timelock,
                safe,
                address(adapter),
                abi.encodeCall(UniswapV4Adapter.setUSDGRoute, (STOCKS[i], _ethUsdPool(), _usdgPool(STOCKS[i], fee, tick)))
            );
        }

        // createBox for AI7 through the timelock
        _tlExec(
            timelock,
            safe,
            address(engine),
            abi.encodeCall(
                BoxEngine.createBox,
                ("AI Bento Box", "AI3", _aiComponents(address(adapter)), 30, 30, uint128(15 ether), "")
            )
        );
        _tlExec(timelock, safe, address(engine), abi.encodeCall(BoxEngine.setPerTxMintCap, (1, uint128(2 ether))));

        // mint + redeem round trip
        address user = makeAddr("user");
        vm.deal(user, 1 ether);
        vm.prank(user);
        uint256 boxOut = engine.mint{value: 0.02 ether}(1, 0, new uint256[](3));
        assertGt(boxOut, 0, "mint out");
        emit log_named_uint("AI3 NAV usd 1e18", engine.navUsdPerBox(1));

        vm.prank(user);
        uint256 ethOut = engine.redeemForETH(1, boxOut, 0, new uint256[](3), user);
        emit log_named_uint("eth in (wei)", 0.02 ether);
        emit log_named_uint("eth out (wei)", ethOut);
        // thin pools: just log all-in cost, assert sane floor (>80% back)
        assertGt(ethOut, (0.02 ether * 8000) / 10000, "round trip under 2000bps");
    }

    function _tlExec(TimelockController tl, address safe, address target, bytes memory data) internal {
        bytes32 salt = keccak256(data);
        uint256 delay = tl.getMinDelay();
        vm.prank(safe);
        tl.schedule(target, 0, data, bytes32(0), salt, delay);
        vm.prank(safe);
        tl.execute(target, 0, data, bytes32(0), salt);
    }

    function _aiComponents(address adapter_) internal view returns (BoxEngine.Component[] memory comps) {
        comps = new BoxEngine.Component[](3);
        uint16[3] memory weights = [uint16(3333), 3333, 3334];
        for (uint256 i; i < 3; ++i) {
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

    function _usdgPool(address token, uint24 fee, int24 tick) internal pure returns (UniswapV4Adapter.PoolKey memory p) {
        p = UniswapV4Adapter.PoolKey({
            currency0: token < USDG ? token : USDG,
            currency1: token < USDG ? USDG : token,
            fee: fee,
            tickSpacing: tick,
            hooks: address(0)
        });
    }

    function _ethDirectPool(address token, uint24 fee, int24 tick) internal pure returns (UniswapV4Adapter.PoolKey memory p) {
        p = UniswapV4Adapter.PoolKey({currency0: address(0), currency1: token, fee: fee, tickSpacing: tick, hooks: address(0)});
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
