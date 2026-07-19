// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;
    bool public paused;
    uint256 public multiplier = 1e18;
    mapping(address => uint256) internal rawBalances;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
        rawBalances[to] += amount;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setMultiplier(uint256 m) external {
        multiplier = m;
    }

    function balanceOf(address a) public view override returns (uint256) {
        return super.balanceOf(a) * multiplier / 1e18;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!paused, "PAUSED");
        return super.transfer(to, amount * 1e18 / multiplier);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!paused, "PAUSED");
        return super.transferFrom(from, to, amount * 1e18 / multiplier);
    }
}

contract MockFeed {
    int256 public answer;
    uint8 public immutable decimals;
    uint256 public updatedAt;

    constructor(int256 a, uint8 d) {
        answer = a;
        decimals = d;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockAdapter {
    mapping(address => uint256) public tokensPerEth;

    function setRate(address token, uint256 rate) external {
        tokensPerEth[token] = rate;
    }

    function swapETHToToken(address token, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 amountOut)
    {
        amountOut = msg.value * tokensPerEth[token] / 1e18;
        require(amountOut >= minOut, "SLIPPAGE");
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", recipient, amountOut));
        require(ok, "mint failed");
    }

    function swapTokenToETH(address token, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        MockERC20(token).transferFrom(msg.sender, address(this), amountIn);
        amountOut = amountIn * 1e18 / tokensPerEth[token];
        require(amountOut >= minOut, "SLIPPAGE");
        payable(recipient).transfer(amountOut);
    }

    function quoteETHToToken(address token, uint256 amountIn) external view returns (uint256 amountOut) {
        amountOut = amountIn * tokensPerEth[token] / 1e18;
    }

    function quoteTokenToETH(address token, uint256 amountIn) external view returns (uint256 amountOut) {
        amountOut = amountIn * 1e18 / tokensPerEth[token];
    }
    receive() external payable {}
}

contract MockRouter {
    address public immutable WETH_TOKEN;
    mapping(address => uint256) public tokensPerEth; // token units per 1 ETH

    constructor(address weth) {
        WETH_TOKEN = weth;
    }

    function WETH() external view returns (address) {
        return WETH_TOKEN;
    }

    function setRate(address token, uint256 rate) external {
        tokensPerEth[token] = rate;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        address out = path[path.length - 1];
        address input = path[0];
        if (input == WETH_TOKEN) amounts[path.length - 1] = amountIn * tokensPerEth[out] / 1e18;
        else amounts[path.length - 1] = amountIn * 1e18 / tokensPerEth[input];
    }

    function swapExactETHForTokens(uint256 minOut, address[] calldata path, address to, uint256)
        external
        payable
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = msg.value;
        address token = path[path.length - 1];
        uint256 out = msg.value * tokensPerEth[token] / 1e18;
        require(out >= minOut, "SLIPPAGE");
        (bool ok,) = token.call(abi.encodeWithSignature("mint(address,uint256)", to, out));
        if (!ok) ERC20(token).transfer(to, out);
        amounts[path.length - 1] = out;
    }

    function swapExactTokensForETH(uint256 amountIn, uint256 minOut, address[] calldata path, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        address token = path[0];
        MockERC20(token).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * 1e18 / tokensPerEth[token];
        require(out >= minOut, "SLIPPAGE");
        amounts[path.length - 1] = out;
        payable(to).transfer(out);
    }
    receive() external payable {}
}
