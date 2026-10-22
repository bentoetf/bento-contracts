// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @notice Optional live Robinhood fork probe. Run with RUN_LIVE_FORK=true once RPC TLS works.
contract RobinhoodForkProbeTest is Test {
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant SUSHI_ROUTER = 0x9A55D3d0c0f09859c7869510f53eD0a30B340766;

    function testOptionalRobinhoodForkReadsStockAndRouter() public {
        bool run = vm.envOr("RUN_LIVE_FORK", false);
        if (!run) return;
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        assertEq(block.chainid, 4663);
        assertGt(NVDA.code.length, 0, "NVDA code missing");
        assertGt(SUSHI_ROUTER.code.length, 0, "Sushi router code missing");
        (bool ok, bytes memory data) = NVDA.staticcall(abi.encodeWithSignature("balanceOf(address)", address(0)));
        assertTrue(ok, "NVDA balanceOf failed");
        assertEq(data.length, 32);
    }
}
