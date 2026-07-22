// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {BoxRegistry} from "../src/BoxRegistry.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

/// @notice Fork test for the second-wave "Elon Box": SPCX + TSLA 50/50.
///         (Rasta 2026-07-20: no single-asset boxes yet; earlier solo
///         SPCX/SPY shapes replaced by this combo.)
///         NFLX excluded: has V4 liquidity but NO Chainlink feed on Robinhood
///         Chain (probed 2026-07-20), so NAV/redeem pricing is impossible.
///         Pool params: SPCX fee=10000/200 (fee=3000 pool ~17% mispriced),
///         TSLA fee=3000/60 (standard MAG7 pool).
contract SecondWaveBoxForkTest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant SUSHI_ROUTER = 0x9A55D3d0c0f09859c7869510f53eD0a30B340766;
    address constant V4_UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant PONS_TOKEN = 0xcDd50D73B45085D71Cb05e2ca238d12C3Bd7bEBD;

    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant SPCX_FEED = 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb;
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;

    TimelockController timelock;
    UniswapV4Adapter adapter;
    BoxEngine engine;
    address safe;

    function testElonBoxMintRedeem() external {
        vm.createSelectFork("robinhood");

        address deployer = makeAddr("deployer");
        safe = makeAddr("safe");
        vm.deal(deployer, 10 ether);

        vm.startPrank(deployer);
        address[] memory props = new address[](1);
        props[0] = safe;
        timelock = new TimelockController(0, props, props, safe);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = PONS_TOKEN;
        FeeCollector collector = new FeeCollector(address(timelock), address(0), PONS_TOKEN, SUSHI_ROUTER, path);
        BoxRegistry registry = new BoxRegistry(deployer);
        adapter = new UniswapV4Adapter(V4_UNIVERSAL_ROUTER, V4_QUOTER, PERMIT2, USDG, deployer);
        engine = new BoxEngine(address(timelock), address(registry), address(collector), PONS_TOKEN, ETH_USD_FEED);
        registry.setRegistrar(address(engine));
        adapter.transferOwnership(address(timelock));
        vm.stopPrank();

        _tlExec(address(collector), abi.encodeCall(FeeCollector.setEngine, (address(engine))));

        // routes via timelock, params from live pool probe
        _tlExec(
            address(adapter),
            abi.encodeCall(UniswapV4Adapter.setUSDGRoute, (SPCX, _ethUsdPool(), _usdgPool(SPCX, 10000, 200)))
        );
        _tlExec(
            address(adapter),
            abi.encodeCall(UniswapV4Adapter.setUSDGRoute, (TSLA, _ethUsdPool(), _usdgPool(TSLA, 3000, 60)))
        );

        // Elon Box: SPCX + TSLA 50/50
        BoxEngine.Component[] memory duo = new BoxEngine.Component[](2);
        duo[0] = BoxEngine.Component({token: SPCX, weightBps: 5000, router: address(adapter), path: _p(SPCX), feed: SPCX_FEED});
        duo[1] = BoxEngine.Component({token: TSLA, weightBps: 5000, router: address(adapter), path: _p(TSLA), feed: TSLA_FEED});
        _tlExec(address(engine), abi.encodeCall(BoxEngine.createBox, ("Elon Box", "ELON", duo, 30, 30, uint128(15 ether), "")));
        _tlExec(address(engine), abi.encodeCall(BoxEngine.setPerTxMintCap, (1, uint128(2 ether))));

        _roundTrip(1, 2);
    }

    function _roundTrip(uint256 boxId, uint256 nComps) internal {
        address user = makeAddr(string.concat("user", vm.toString(boxId)));
        vm.deal(user, 1 ether);
        vm.prank(user);
        uint256 boxOut = engine.mint{value: 0.02 ether}(boxId, 0, new uint256[](nComps));
        assertGt(boxOut, 0, "mint out");
        emit log_named_uint(string.concat("box ", vm.toString(boxId), " NAV usd 1e18"), engine.navUsdPerBox(boxId));
        vm.prank(user);
        uint256 ethOut = engine.redeemForETH(boxId, boxOut, 0, new uint256[](nComps), user);
        emit log_named_uint(string.concat("box ", vm.toString(boxId), " eth out (wei, 0.02 in)"), ethOut);
        assertGt(ethOut, (0.02 ether * 8000) / 10000, "round trip under 2000bps");
    }

    function _tlExec(address target, bytes memory data) internal {
        bytes32 salt = keccak256(data);
        uint256 delay = timelock.getMinDelay();
        vm.prank(safe);
        timelock.schedule(target, 0, data, bytes32(0), salt, delay);
        vm.prank(safe);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    function _p(address token) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = address(0);
        p[1] = token;
    }

    function _ethUsdPool() internal pure returns (UniswapV4Adapter.PoolKey memory p) {
        p = UniswapV4Adapter.PoolKey({currency0: address(0), currency1: USDG, fee: 460, tickSpacing: 9, hooks: address(0)});
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
}
