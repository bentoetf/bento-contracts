// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DevLock} from "../src/periphery/DevLock.sol";

/// Deploys the DevLock and prints the address. Funding the lock is a separate
/// plain ERC20 transfer from the dev wallet (do it after verifying the deploy).
///
/// env:
///   BENTO_TOKEN       - BENTO ERC20 address
///   LOCK_BENEFICIARY  - who can withdraw after unlock (dev wallet or safe)
///   LOCK_DURATION_DAYS - lock length in days from now (e.g. 180)
contract DevLockDeploy is Script {
    function run() external {
        address token = vm.envAddress("BENTO_TOKEN");
        address beneficiary = vm.envAddress("LOCK_BENEFICIARY");
        uint256 durationDays = vm.envUint("LOCK_DURATION_DAYS");
        uint256 unlockTime = block.timestamp + durationDays * 1 days;

        vm.startBroadcast();
        DevLock lock = new DevLock(IERC20(token), beneficiary, unlockTime);
        vm.stopBroadcast();

        console2.log("DevLock deployed:", address(lock));
        console2.log("token:", token);
        console2.log("beneficiary:", beneficiary);
        console2.log("unlockTime:", unlockTime);
    }
}
