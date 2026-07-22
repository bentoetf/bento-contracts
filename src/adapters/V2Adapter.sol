// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapAdapter} from "./ISwapAdapter.sol";

interface IV2RouterLike {
    function WETH() external pure returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/// @notice Thin wrapper around legacy V2-style router logic for adapter-level mocks/tests.
contract V2Adapter is ISwapAdapter {
    using SafeERC20 for IERC20;

    IV2RouterLike public immutable router;
    address public immutable weth;

    mapping(address token => address[] path) internal ethToTokenPath;

    error RouteNotSet(address token);

    constructor(address _router, address _weth) {
        router = IV2RouterLike(_router);
        weth = _weth;
    }

    function setRoute(address token, address[] calldata path) external {
        require(path.length >= 2 && path[0] == weth && path[path.length - 1] == token, "bad path");
        delete ethToTokenPath[token];
        for (uint256 i; i < path.length; ++i) {
            ethToTokenPath[token].push(path[i]);
        }
    }

    function swapETHToToken(address token, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 amountOut)
    {
        address[] memory path = _path(token);
        uint256[] memory amounts =
            router.swapExactETHForTokens{value: msg.value}(minOut, path, recipient, block.timestamp);
        amountOut = amounts[amounts.length - 1];
    }

    function swapTokenToETH(address token, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        address[] memory forward = _path(token);
        address[] memory reverse = new address[](forward.length);
        for (uint256 i; i < forward.length; ++i) {
            reverse[i] = forward[forward.length - 1 - i];
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(token).forceApprove(address(router), amountIn);
        uint256[] memory amounts = router.swapExactTokensForETH(amountIn, minOut, reverse, recipient, block.timestamp);
        amountOut = amounts[amounts.length - 1];
    }

    function quoteETHToToken(address token, uint256 amountIn) external view returns (uint256 amountOut) {
        address[] memory path = _path(token);
        uint256[] memory amounts = router.getAmountsOut(amountIn, path);
        amountOut = amounts[amounts.length - 1];
    }

    function quoteTokenToETH(address token, uint256 amountIn) external view returns (uint256 amountOut) {
        address[] memory forward = _path(token);
        address[] memory reverse = new address[](forward.length);
        for (uint256 i; i < forward.length; ++i) {
            reverse[i] = forward[forward.length - 1 - i];
        }
        uint256[] memory amounts = router.getAmountsOut(amountIn, reverse);
        amountOut = amounts[amounts.length - 1];
    }

    function _path(address token) internal view returns (address[] memory path) {
        path = ethToTokenPath[token];
        if (path.length == 0) revert RouteNotSet(token);
    }
}
