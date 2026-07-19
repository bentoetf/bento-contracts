// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Decimals {
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IBoxToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IBoxVault {
    function transferToken(address token, address to, uint256 amount) external;
    function approveToken(address token, address spender, uint256 amount) external;
    function sweepNonComponent(address token, address to) external;
}

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IV2Router {
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

interface IScaledUIAmountLite {
    function uiMultiplier() external view returns (uint256);
}

interface ISwapAdapterLike {
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
