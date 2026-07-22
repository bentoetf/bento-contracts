// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Hard timelock for the BENTO dev supply. Tokens sent here are
/// unrecoverable until `unlockTime`, then only `beneficiary` can release.
/// No owner, no upgrade, no early exit.
contract DevLock {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    address public immutable beneficiary;
    uint256 public immutable unlockTime;

    event Released(uint256 amount);

    error TooEarly(uint256 nowTs, uint256 unlockTs);
    error NotBeneficiary();

    constructor(IERC20 token_, address beneficiary_, uint256 unlockTime_) {
        require(address(token_) != address(0) && beneficiary_ != address(0), "zero addr");
        require(unlockTime_ > block.timestamp, "unlock in past");
        token = token_;
        beneficiary = beneficiary_;
        unlockTime = unlockTime_;
    }

    function locked() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function release() external {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        if (block.timestamp < unlockTime) revert TooEarly(block.timestamp, unlockTime);
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(beneficiary, amount);
        emit Released(amount);
    }
}
