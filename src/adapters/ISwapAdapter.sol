// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal swap adapter interface for Bento Engine integration after Phase 1B.
/// @dev V4 quoters are not guaranteed view, so quote functions are external non-view.
interface ISwapAdapter {
    function swapETHToToken(address token, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 amountOut);

    function swapTokenToETH(address token, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut);

    function quoteETHToToken(address token, uint256 amountIn) external returns (uint256 amountOut);

    function quoteTokenToETH(address token, uint256 amountIn) external returns (uint256 amountOut);
}
