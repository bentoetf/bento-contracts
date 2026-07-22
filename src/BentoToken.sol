// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Fixed-supply BENTO protocol token with capped DEX-pair transfer tax.
/// @dev No mint after construction, no pause, no owner. Admin is intended to be the production timelock.
contract BentoToken is ERC20, ERC20Permit {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint16 public constant MAX_TAX_BPS = 300;
    uint16 public constant BPS = 10_000;

    address public immutable admin;
    address public devWallet;
    uint16 public taxBps = MAX_TAX_BPS;
    bool public taxLockedForever;

    mapping(address => bool) public taxedPair;
    mapping(address => bool) public taxExempt;

    error NotAdmin();
    error ZeroAddress();
    error TaxTooHigh();
    error TaxLocked();

    event TaxBpsSet(uint16 taxBps);
    event DevWalletSet(address indexed devWallet);
    event TaxedPairSet(address indexed pair, bool enabled);
    event TaxExemptSet(address indexed account, bool enabled);
    event TaxLockedForever();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address deployer, address admin_, address devWallet_)
        ERC20("Bento Protocol", "BENTO")
        ERC20Permit("Bento Protocol")
    {
        if (deployer == address(0) || admin_ == address(0) || devWallet_ == address(0)) revert ZeroAddress();
        admin = admin_;
        devWallet = devWallet_;
        taxExempt[deployer] = true;
        taxExempt[admin_] = true;
        taxExempt[devWallet_] = true;
        emit TaxExemptSet(deployer, true);
        emit TaxExemptSet(admin_, true);
        emit TaxExemptSet(devWallet_, true);
        emit DevWalletSet(devWallet_);
        emit TaxBpsSet(MAX_TAX_BPS);
        _mint(deployer, INITIAL_SUPPLY);
    }

    /// @notice Sets buy/sell tax in bps. Capped at MAX_TAX_BPS and disabled forever after lockTaxForever().
    function setTaxBps(uint16 taxBps_) external onlyAdmin {
        if (taxLockedForever) revert TaxLocked();
        if (taxBps_ > MAX_TAX_BPS) revert TaxTooHigh();
        taxBps = taxBps_;
        emit TaxBpsSet(taxBps_);
    }

    /// @notice Updates the wallet that receives BENTO tax proceeds.
    function setDevWallet(address devWallet_) external onlyAdmin {
        if (devWallet_ == address(0)) revert ZeroAddress();
        devWallet = devWallet_;
        emit DevWalletSet(devWallet_);
    }

    /// @notice Marks a DEX pair/pool as taxable. Plain wallet transfers remain untaxed.
    function setTaxedPair(address pair, bool enabled) external onlyAdmin {
        if (pair == address(0)) revert ZeroAddress();
        taxedPair[pair] = enabled;
        emit TaxedPairSet(pair, enabled);
    }

    /// @notice Exempts protocol addresses from tax when either transfer side is exempt.
    function setTaxExempt(address account, bool enabled) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        taxExempt[account] = enabled;
        emit TaxExemptSet(account, enabled);
    }

    /// @notice Permanently disables the transfer tax. This cannot be reversed.
    function lockTaxForever() external onlyAdmin {
        taxBps = 0;
        taxLockedForever = true;
        emit TaxBpsSet(0);
        emit TaxLockedForever();
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fee;
        if (
            from != address(0) && to != address(0) && taxBps != 0 && (taxedPair[from] || taxedPair[to])
                && !taxExempt[from] && !taxExempt[to]
        ) {
            fee = value * taxBps / BPS;
        }

        if (fee != 0) {
            super._update(from, devWallet, fee);
            unchecked {
                value -= fee;
            }
        }
        super._update(from, to, value);
    }
}
