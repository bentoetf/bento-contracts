// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapAdapter} from "./ISwapAdapter.sol";

interface IUniversalRouterLike {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

interface IV4QuoterLike {
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    struct QuoteExactParams {
        address exactCurrency;
        PathKey[] path;
        uint128 exactAmount;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
    function quoteExactInput(QuoteExactParams memory params) external returns (uint256 amountOut, uint256 gasEstimate);
}

interface IPermit2AllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Uniswap V4 UniversalRouter adapter spike for Bento Phase 1B.
/// @dev Supports exact-input routes configured as direct ETH<->token or ETH<->USDG<->token.
contract UniswapV4Adapter is ISwapAdapter, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant COMMAND_V4_SWAP = 0x10;
    uint256 internal constant ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant ACTION_SWAP_EXACT_IN = 0x07;
    uint256 internal constant ACTION_SETTLE_ALL = 0x0c;
    uint256 internal constant ACTION_TAKE_ALL = 0x0f;

    address public constant NATIVE_ETH = address(0);

    IUniversalRouterLike public immutable universalRouter;
    IV4QuoterLike public immutable quoter;
    IPermit2AllowanceTransfer public immutable permit2;
    address public immutable usdg;

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct RouteConfig {
        bool exists;
        bool viaUSDG;
        PoolKey ethPool;
        PoolKey usdgPool;
    }

    mapping(address token => RouteConfig) public routes;

    event RouteSet(address indexed token, bool viaUSDG, PoolKey ethPool, PoolKey usdgPool);

    error RouteNotSet(address token);
    error InvalidAmount();
    error SwapFailed();

    constructor(address _universalRouter, address _quoter, address _permit2, address _usdg, address initialOwner)
        Ownable(initialOwner)
    {
        universalRouter = IUniversalRouterLike(_universalRouter);
        quoter = IV4QuoterLike(_quoter);
        permit2 = IPermit2AllowanceTransfer(_permit2);
        usdg = _usdg;
    }

    receive() external payable {}

    function setDirectRoute(address token, PoolKey calldata ethPool) external onlyOwner {
        routes[token] = RouteConfig({exists: true, viaUSDG: false, ethPool: ethPool, usdgPool: emptyPool()});
        emit RouteSet(token, false, ethPool, emptyPool());
    }

    function setUSDGRoute(address token, PoolKey calldata ethUsdgPool, PoolKey calldata usdgTokenPool)
        external
        onlyOwner
    {
        routes[token] = RouteConfig({exists: true, viaUSDG: true, ethPool: ethUsdgPool, usdgPool: usdgTokenPool});
        emit RouteSet(token, true, ethUsdgPool, usdgTokenPool);
    }

    function swapETHToToken(address token, uint256 minOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.value == 0 || recipient == address(0)) revert InvalidAmount();
        RouteConfig memory route = _route(token);
        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        universalRouter.execute{value: msg.value}(
            bytes.concat(bytes1(uint8(COMMAND_V4_SWAP))), _encodeExactIn(route, NATIVE_ETH, token, msg.value, minOut)
        );
        amountOut = IERC20(token).balanceOf(address(this)) - beforeBal;
        if (amountOut < minOut) revert SwapFailed();
        IERC20(token).safeTransfer(recipient, amountOut);
    }

    function swapTokenToETH(address token, uint256 amountIn, uint256 minOut, address recipient)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || recipient == address(0)) revert InvalidAmount();
        RouteConfig memory route = _route(token);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(token).forceApprove(address(permit2), amountIn);
        permit2.approve(token, address(universalRouter), uint160(amountIn), type(uint48).max);

        uint256 beforeBal = address(this).balance;
        universalRouter.execute(
            bytes.concat(bytes1(uint8(COMMAND_V4_SWAP))), _encodeExactIn(route, token, NATIVE_ETH, amountIn, minOut)
        );
        amountOut = address(this).balance - beforeBal;
        if (amountOut < minOut) revert SwapFailed();
        (bool ok,) = recipient.call{value: amountOut}("");
        require(ok, "eth send failed");
    }

    function quoteETHToToken(address token, uint256 amountIn) external returns (uint256 amountOut) {
        RouteConfig memory route = _route(token);
        amountOut = _quote(route, NATIVE_ETH, token, amountIn);
    }

    function quoteTokenToETH(address token, uint256 amountIn) external returns (uint256 amountOut) {
        RouteConfig memory route = _route(token);
        amountOut = _quote(route, token, NATIVE_ETH, amountIn);
    }

    function emptyPool() public pure returns (PoolKey memory pool) {}

    function _route(address token) internal view returns (RouteConfig memory route) {
        route = routes[token];
        if (!route.exists) revert RouteNotSet(token);
    }

    function _encodeExactIn(
        RouteConfig memory route,
        address currencyIn,
        address currencyOut,
        uint256 amountIn,
        uint256 minOut
    ) internal view returns (bytes[] memory inputs) {
        bytes memory actions = bytes.concat(
            route.viaUSDG ? bytes1(uint8(ACTION_SWAP_EXACT_IN)) : bytes1(uint8(ACTION_SWAP_EXACT_IN_SINGLE)),
            bytes1(uint8(ACTION_SETTLE_ALL)),
            bytes1(uint8(ACTION_TAKE_ALL))
        );
        bytes[] memory params = new bytes[](3);
        if (route.viaUSDG) {
            params[0] = abi.encode(_exactInputParams(route, currencyIn, currencyOut, amountIn, minOut));
        } else {
            params[0] = abi.encode(_exactInputSingleParams(route.ethPool, currencyIn, amountIn, minOut));
        }
        params[1] = abi.encode(currencyIn, amountIn);
        params[2] = abi.encode(currencyOut, minOut);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function _quote(RouteConfig memory route, address currencyIn, address currencyOut, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        if (route.viaUSDG) {
            (amountOut,) = quoter.quoteExactInput(_quoteExactParams(route, currencyIn, currencyOut, amountIn));
        } else {
            (amountOut,) = quoter.quoteExactInputSingle(_quoteExactSingleParams(route.ethPool, currencyIn, amountIn));
        }
    }

    function _exactInputSingleParams(PoolKey memory pool, address currencyIn, uint256 amountIn, uint256 minOut)
        internal
        pure
        returns (IV4ExactInputSingleParams memory p)
    {
        p.poolKey = pool;
        p.zeroForOne = currencyIn == pool.currency0;
        p.amountIn = uint128(amountIn);
        p.amountOutMinimum = uint128(minOut);
        p.minHopPriceX36 = 0;
        p.hookData = "";
    }

    function _exactInputParams(
        RouteConfig memory route,
        address currencyIn,
        address currencyOut,
        uint256 amountIn,
        uint256 minOut
    ) internal view returns (IV4ExactInputParams memory p) {
        p.currencyIn = currencyIn;
        p.path = new IV4PathKey[](2);
        if (currencyIn == NATIVE_ETH) {
            p.path[0] = _pathKey(usdg, route.ethPool);
            p.path[1] = _pathKey(currencyOut, route.usdgPool);
        } else {
            p.path[0] = _pathKey(usdg, route.usdgPool);
            p.path[1] = _pathKey(NATIVE_ETH, route.ethPool);
        }
        p.minHopPriceX36 = new uint256[](0);
        p.amountIn = uint128(amountIn);
        p.amountOutMinimum = uint128(minOut);
    }

    function _quoteExactSingleParams(PoolKey memory pool, address currencyIn, uint256 amountIn)
        internal
        pure
        returns (IV4QuoterLike.QuoteExactSingleParams memory p)
    {
        p.poolKey = IV4QuoterLike.PoolKey(pool.currency0, pool.currency1, pool.fee, pool.tickSpacing, pool.hooks);
        p.zeroForOne = currencyIn == pool.currency0;
        p.exactAmount = uint128(amountIn);
        p.hookData = "";
    }

    function _quoteExactParams(RouteConfig memory route, address currencyIn, address currencyOut, uint256 amountIn)
        internal
        view
        returns (IV4QuoterLike.QuoteExactParams memory p)
    {
        p.exactCurrency = currencyIn;
        p.path = new IV4QuoterLike.PathKey[](2);
        if (currencyIn == NATIVE_ETH) {
            p.path[0] = _quotePathKey(usdg, route.ethPool);
            p.path[1] = _quotePathKey(currencyOut, route.usdgPool);
        } else {
            p.path[0] = _quotePathKey(usdg, route.usdgPool);
            p.path[1] = _quotePathKey(NATIVE_ETH, route.ethPool);
        }
        p.exactAmount = uint128(amountIn);
    }

    function _pathKey(address intermediate, PoolKey memory pool) internal pure returns (IV4PathKey memory k) {
        k.intermediateCurrency = intermediate;
        k.fee = pool.fee;
        k.tickSpacing = pool.tickSpacing;
        k.hooks = pool.hooks;
        k.hookData = "";
    }

    function _quotePathKey(address intermediate, PoolKey memory pool)
        internal
        pure
        returns (IV4QuoterLike.PathKey memory k)
    {
        k.intermediateCurrency = intermediate;
        k.fee = pool.fee;
        k.tickSpacing = pool.tickSpacing;
        k.hooks = pool.hooks;
        k.hookData = "";
    }

    struct IV4PathKey {
        address intermediateCurrency;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        bytes hookData;
    }

    struct IV4ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    struct IV4ExactInputParams {
        address currencyIn;
        IV4PathKey[] path;
        uint256[] minHopPriceX36;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }
}
