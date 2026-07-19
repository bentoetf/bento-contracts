// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Minimal engine-minted ERC20 representing one Bento basket box.
contract BoxToken is ERC20, ERC20Permit {
    address public immutable engine;

    error NotEngine();

    constructor(string memory name_, string memory symbol_, address engine_) ERC20(name_, symbol_) ERC20Permit(name_) {
        engine = engine_;
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert NotEngine();
        _;
    }

    /// @notice Mints box shares. Callable only by the configured BoxEngine.
    function mint(address to, uint256 amount) external onlyEngine {
        _mint(to, amount);
    }

    /// @notice Burns box shares from an account. Callable only by the configured BoxEngine.
    function burn(address from, uint256 amount) external onlyEngine {
        _burn(from, amount);
    }
}
