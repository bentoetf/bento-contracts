// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

/// @notice Generates timelock calldata for the second-wave boxes: SPCX solo
/// and SPY solo. Run AFTER the pons core deploy, with live addresses:
///
///   ADAPTER_ADDRESS=0x... forge script script/SecondWaveCalldata.s.sol
///
/// Writes calldata files to out/. Schedule + execute each through the
/// timelock (24h delay applies post-bootstrap):
///   wave2-01 -> target = adapter (setUSDGRoute SPCX, fee=10000 tick=200)
///   wave2-02 -> target = adapter (setUSDGRoute SPY,  fee=3000  tick=60)
///   wave2-03 -> target = engine  (createBox "SpaceX Box" / SPCXB)
///   wave2-04 -> target = engine  (createBox "S&P 500 Box" / SPYB)
///   wave2-05 -> target = engine  (setPerTxMintCap for SPCXB box id)
///   wave2-06 -> target = engine  (setPerTxMintCap for SPYB box id)
///
/// NOTE: box ids in 05/06 assume SPCXB=2, SPYB=3 (MAG7=1, minted in order).
/// If AI3 ships first the ids shift; set BOX_ID_SPCX / BOX_ID_SPY env vars.
///
/// NFLX excluded despite $40k pool liquidity: no Chainlink feed exists on
/// Robinhood Chain for NFLX (verified against the full EACAggregatorProxy
/// set on-chain, 2026-07-20), so NAV/redeem pricing is impossible.
/// Pool params from SecondWavePoolProbeFork (SPCX fee=3000 pool exists but
/// quotes ~17% under feed; the fee=10000 pool is the honest one).
contract SecondWaveCalldata is Script {
    address constant NATIVE_ETH = address(0);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant SPCX_FEED = 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb;
    address constant SPY_FEED = 0x319724394D3A0e3669269846abE664Cd621f9f6A;

    function run() external {
        address adapter_ = vm.envAddress("ADAPTER_ADDRESS");
        uint256 idSpcx = vm.envOr("BOX_ID_SPCX", uint256(2));
        uint256 idSpy = vm.envOr("BOX_ID_SPY", uint256(3));

        vm.writeFile(
            "out/wave2-01-adapter-setUSDGRoute-SPCX.calldata.txt",
            vm.toString(
                abi.encodeCall(UniswapV4Adapter.setUSDGRoute, (SPCX, _ethUsdPool(), _usdgPool(SPCX, 10000, 200)))
            )
        );
        vm.writeFile(
            "out/wave2-02-adapter-setUSDGRoute-SPY.calldata.txt",
            vm.toString(abi.encodeCall(UniswapV4Adapter.setUSDGRoute, (SPY, _ethUsdPool(), _usdgPool(SPY, 3000, 60))))
        );
        vm.writeFile(
            "out/wave2-03-engine-createBox-SPCXB.calldata.txt",
            vm.toString(
                abi.encodeCall(
                    BoxEngine.createBox,
                    ("SpaceX Box", "SPCXB", _solo(SPCX, SPCX_FEED, adapter_), 30, 30, uint128(15 ether), "")
                )
            )
        );
        vm.writeFile(
            "out/wave2-04-engine-createBox-SPYB.calldata.txt",
            vm.toString(
                abi.encodeCall(
                    BoxEngine.createBox,
                    ("S&P 500 Box", "SPYB", _solo(SPY, SPY_FEED, adapter_), 30, 30, uint128(15 ether), "")
                )
            )
        );
        vm.writeFile(
            "out/wave2-05-engine-setPerTxMintCap-SPCXB.calldata.txt",
            vm.toString(abi.encodeCall(BoxEngine.setPerTxMintCap, (idSpcx, uint128(2 ether))))
        );
        vm.writeFile(
            "out/wave2-06-engine-setPerTxMintCap-SPYB.calldata.txt",
            vm.toString(abi.encodeCall(BoxEngine.setPerTxMintCap, (idSpy, uint128(2 ether))))
        );
    }

    function _solo(address token, address feed, address adapter_)
        internal
        pure
        returns (BoxEngine.Component[] memory comps)
    {
        comps = new BoxEngine.Component[](1);
        address[] memory p = new address[](2);
        p[0] = USDG;
        p[1] = token;
        comps[0] = BoxEngine.Component({token: token, weightBps: 10000, router: adapter_, path: p, feed: feed});
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
