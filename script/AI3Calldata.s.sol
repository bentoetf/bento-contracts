// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

/// @notice Generates timelock calldata for launching the AI3 box (box #2)
/// post-core-deploy. Run AFTER the pons deploy, with the live addresses:
///
///   ADAPTER_ADDRESS=0x... ENGINE_ADDRESS=0x... \
///   forge script script/AI3Calldata.s.sol
///
/// Writes 4 calldata files to out/. Schedule + execute each through the
/// timelock (24h delay applies post-bootstrap):
///   ai3-01..03 -> target = adapter (setUSDGRoute for NVDA, AMD, MU)
///   ai3-04     -> target = engine  (createBox "AI Bento Box" / AI3)
///
/// Pool reality (probed 2026-07-20, re-probe with AIPoolProbeForkTest):
///   NVDA/USDG fee=3000 tick=60; AMD & MU /USDG fee=10000 tick=200.
///   TSM/PLTR/ORCL/CRWV excluded: pools are dust or mispriced vs feed.
contract AI3Calldata is Script {
    address constant NATIVE_ETH = address(0);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address[3] STOCKS = [
        address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC), // NVDA
        address(0x86923f96303D656E4aa86D9d42D1e57ad2023fdC), // AMD
        address(0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD) // MU
    ];

    address[3] FEEDS = [
        address(0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15), // NVDA/USD
        address(0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72), // AMD/USD
        address(0x425EEFdCf05ed6526C3cE61Af99429A228a6d596) // MU/USD
    ];

    string[3] NAMES = ["NVDA", "AMD", "MU"];

    function run() external {
        address adapter_ = vm.envAddress("ADAPTER_ADDRESS");

        for (uint256 i; i < 3; ++i) {
            uint24 fee = i == 0 ? 3000 : 10000;
            int24 tick = i == 0 ? int24(60) : int24(200);
            bytes memory routeCall =
                abi.encodeCall(UniswapV4Adapter.setUSDGRoute, (STOCKS[i], _ethUsdPool(), _usdgPool(STOCKS[i], fee, tick)));
            vm.writeFile(
                string.concat("out/ai3-0", vm.toString(i + 1), "-adapter-setUSDGRoute-", NAMES[i], ".calldata.txt"),
                vm.toString(routeCall)
            );
        }

        bytes memory createBox =
            abi.encodeCall(BoxEngine.createBox, ("AI Bento Box", "AI3", _aiComponents(adapter_), 30, 30, uint128(15 ether), ""));
        vm.writeFile("out/ai3-04-engine-createBox.calldata.txt", vm.toString(createBox));
    }

    function _aiComponents(address adapter_) internal view returns (BoxEngine.Component[] memory comps) {
        comps = new BoxEngine.Component[](3);
        uint16[3] memory weights = [uint16(3333), 3333, 3334];
        for (uint256 i; i < 3; ++i) {
            address[] memory p = new address[](2);
            p[0] = USDG;
            p[1] = STOCKS[i];
            comps[i] = BoxEngine.Component({
                token: STOCKS[i],
                weightBps: weights[i],
                router: adapter_,
                path: p,
                feed: FEEDS[i]
            });
        }
    }

    function _ethUsdPool() internal pure returns (UniswapV4Adapter.PoolKey memory p) {
        p = UniswapV4Adapter.PoolKey({currency0: NATIVE_ETH, currency1: USDG, fee: 460, tickSpacing: 9, hooks: address(0)});
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
