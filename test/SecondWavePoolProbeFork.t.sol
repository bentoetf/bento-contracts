// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

interface IV4QuoterProbe2 {
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

/// @notice Probe V4 USDG pools for second-wave box candidates (SPCX, SPY, NFLX, QQQ, SLV, USO).
contract SecondWavePoolProbeForkTest is Test {
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    function testProbePools() external {
        vm.createSelectFork("robinhood");
        string[6] memory syms = ["SPCX", "SPY", "NFLX", "QQQ", "SLV", "USO"];
        address[6] memory stocks = [
            address(0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa),
            address(0x117cc2133c37B721F49dE2A7a74833232B3B4C0C),
            address(0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8),
            address(0xD5f3879160bc7c32ebb4dC785F8a4F505888de68),
            address(0x411eFb0E7f985935DAec3D4C3ebaEa0d0AD7D89f),
            address(0xa30FA36Db767ad9eD3f7a60fC79526fB4d56D344)
        ];
        uint24[8] memory fees = [uint24(460), 500, 3000, 10000, 100, 200, 1000, 2500];
        int24[8] memory ticks = [int24(9), 10, 60, 200, 1, 4, 20, 50];

        for (uint256 i; i < 6; ++i) {
            for (uint256 f; f < 8; ++f) {
                IV4QuoterProbe2.PoolKey memory k = IV4QuoterProbe2.PoolKey({
                    currency0: stocks[i] < USDG ? stocks[i] : USDG,
                    currency1: stocks[i] < USDG ? USDG : stocks[i],
                    fee: fees[f],
                    tickSpacing: ticks[f],
                    hooks: address(0)
                });
                try IV4QuoterProbe2(V4_QUOTER).quoteExactInputSingle(
                    IV4QuoterProbe2.QuoteExactSingleParams({
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
        }
    }
}
