// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

/// @notice Generates timelock calldata for the second-wave "Elon Box":
/// SPCX + TSLA 50/50. (No single-asset boxes per Rasta 2026-07-20.)
/// Run AFTER the pons core deploy, with live addresses:
///
///   ADAPTER_ADDRESS=0x... forge script script/SecondWaveCalldata.s.sol
///
/// Writes calldata files to out/. Schedule + execute each through the
/// timelock (24h delay applies post-bootstrap):
///   wave2-01 -> target = adapter (setUSDGRoute SPCX, fee=10000 tick=200)
///   wave2-02 -> target = engine  (createBox "Elon Box" / ELON)
///   wave2-03 -> target = engine  (setPerTxMintCap for ELON box id)
///
/// TSLA route NOT included: already set by PonsDeploy (MAG7 constituent).
/// Box id in 03 assumes ELON=2 (MAG7=1). If AI3 ships first the id shifts;
/// override with BOX_ID_ELON env var.
///
/// NFLX excluded despite $40k pool liquidity: no Chainlink feed exists on
/// Robinhood Chain for NFLX (verified against the full EACAggregatorProxy
/// set on-chain, 2026-07-20), so NAV/redeem pricing is impossible.
/// SPCX pool params from SecondWavePoolProbeFork (fee=3000 pool exists but
/// quotes ~17% under feed; the fee=10000 pool is the honest one).
contract SecondWaveCalldata is Script {
    address constant NATIVE_ETH = address(0);
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address constant SPCX = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant SPCX_FEED = 0xB265810950ba6c5C0Ff821c9963014a56fD8Bffb;
    address constant TSLA_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;

    function run() external {
        address adapter_ = vm.envAddress("ADAPTER_ADDRESS");
        uint256 idElon = vm.envOr("BOX_ID_ELON", uint256(2));

        vm.writeFile(
            "out/wave2-01-adapter-setUSDGRoute-SPCX.calldata.txt",
            vm.toString(
                abi.encodeCall(UniswapV4Adapter.setUSDGRoute, (SPCX, _ethUsdPool(), _usdgPool(SPCX, 10000, 200)))
            )
        );
        vm.writeFile(
            "out/wave2-02-engine-createBox-ELON.calldata.txt",
            vm.toString(
                abi.encodeCall(
                    BoxEngine.createBox, ("Elon Box", "ELON", _elonComponents(adapter_), 30, 30, uint128(15 ether), "")
                )
            )
        );
        vm.writeFile(
            "out/wave2-03-engine-setPerTxMintCap-ELON.calldata.txt",
            vm.toString(abi.encodeCall(BoxEngine.setPerTxMintCap, (idElon, uint128(2 ether))))
        );
    }

    function _elonComponents(address adapter_) internal pure returns (BoxEngine.Component[] memory comps) {
        comps = new BoxEngine.Component[](2);
        address[2] memory toks = [SPCX, TSLA];
        address[2] memory feeds = [SPCX_FEED, TSLA_FEED];
        for (uint256 i; i < 2; ++i) {
            address[] memory p = new address[](2);
            p[0] = USDG;
            p[1] = toks[i];
            comps[i] =
                BoxEngine.Component({token: toks[i], weightBps: 5000, router: adapter_, path: p, feed: feeds[i]});
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
