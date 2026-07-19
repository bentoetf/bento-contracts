// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Per-box custody vault. Engine is the only authority; no admin sweep for components.
contract BoxVault {
    using SafeERC20 for IERC20;

    address public immutable engine;
    mapping(address => bool) public isComponent;

    error NotEngine();
    error ComponentUnsweepable();

    event ComponentMarked(address indexed token, bool indexed enabled);
    event TokenTransferred(address indexed token, address indexed to, uint256 amount);
    event NonComponentSwept(address indexed token, address indexed to, uint256 amount);

    constructor(address engine_, address[] memory components_) {
        engine = engine_;
        for (uint256 i; i < components_.length; ++i) {
            isComponent[components_[i]] = true;
            emit ComponentMarked(components_[i], true);
        }
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert NotEngine();
        _;
    }

    /// @notice Transfers a token from this vault. Only BoxEngine can call; may revert if issuer pause/blocklist fires.
    function transferToken(address token, address to, uint256 amount) external onlyEngine {
        IERC20(token).safeTransfer(to, amount);
        emit TokenTransferred(token, to, amount);
    }

    /// @notice Approves a router for a vault-held token. Only BoxEngine can call.
    function approveToken(address token, address spender, uint256 amount) external onlyEngine {
        IERC20(token).forceApprove(spender, amount);
    }

    /// @notice Sweeps accidental tokens that are not configured components. Component assets are unsweepable by construction.
    function sweepNonComponent(address token, address to) external onlyEngine {
        if (isComponent[token]) revert ComponentUnsweepable();
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        emit NonComponentSwept(token, to, amount);
    }
}
