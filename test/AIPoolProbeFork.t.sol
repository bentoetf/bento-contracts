// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

interface IV4QuoterProbe {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @notice Probe which V4 USDG/stock pool params are live for AI box candidates.
contract AIPoolProbeForkTest is Test {
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function testProbePools() external {
        vm.createSelectFork("robinhood");
        string[7] memory syms = ["NVDA", "AMD", "TSM", "MU", "PLTR", "ORCL", "CRWV"];
        address[7] memory stocks = [
            address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC),
            address(0x86923f96303D656E4aa86D9d42D1e57ad2023fdC),
            address(0x58FfE4a942d3885bAa22D7520691F611EF09e7AA),
            address(0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD),
            address(0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A),
            address(0xb0992820E760d836549ba69BC7598b4af75dEE03),
            address(0x5f10A1C971B69e47e059e1dC91901B59b3fB49C3)
        ];
        uint24[8] memory fees = [uint24(460), 500, 3000, 10000, 100, 200, 1000, 2500];
        int24[8] memory ticks = [int24(9), 10, 60, 200, 1, 4, 20, 50];

        for (uint256 i; i < 7; ++i) {
            // probe USDG->stock with $50 USDG (6 decimals)
            for (uint256 f; f < 8; ++f) {
                IV4QuoterProbe.PoolKey memory k = IV4QuoterProbe.PoolKey({
                    currency0: stocks[i] < USDG ? stocks[i] : USDG,
                    currency1: stocks[i] < USDG ? USDG : stocks[i],
                    fee: fees[f],
                    tickSpacing: ticks[f],
                    hooks: address(0)
                });
                try IV4QuoterProbe(V4_QUOTER).quoteExactInputSingle(
                    IV4QuoterProbe.QuoteExactSingleParams({
                        poolKey: k,
                        zeroForOne: USDG == k.currency0,
                        exactAmount: 50e6,
                        hookData: ""
                    })
                ) returns (uint256 amountOut, uint256) {
                    emit log_string(
                        string.concat(syms[i], " fee=", vm.toString(fees[f]), " out=", vm.toString(amountOut))
                    );
                } catch {}
            }
            // also probe direct ETH pool (0.02 ETH in)
            for (uint256 f; f < 8; ++f) {
                IV4QuoterProbe.PoolKey memory k = IV4QuoterProbe.PoolKey({
                    currency0: address(0),
                    currency1: stocks[i],
                    fee: fees[f],
                    tickSpacing: ticks[f],
                    hooks: address(0)
                });
                try IV4QuoterProbe(V4_QUOTER).quoteExactInputSingle(
                    IV4QuoterProbe.QuoteExactSingleParams({
                        poolKey: k, zeroForOne: true, exactAmount: 0.02 ether, hookData: ""
                    })
                ) returns (uint256 amountOut, uint256) {
                    emit log_string(
                        string.concat(syms[i], " ETHdirect fee=", vm.toString(fees[f]), " out=", vm.toString(amountOut))
                    );
                } catch {}
            }
        }
    }
}
