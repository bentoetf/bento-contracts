// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniversalRouterZ {
    function execute(bytes calldata commands, bytes[] calldata inputs) external payable;
}

interface IPermit2Z {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IBoxEngineZ {
    function mint(uint256 boxId, uint256 minBoxOut, address recipient, uint256[] calldata minComponentOut)
        external
        payable
        returns (uint256 boxOut);
}

/// @notice Zap USDG straight into a Bento box: swaps USDG -> native ETH through
///         the Uniswap V4 ETH/USDG pool, then mints the box in the same tx.
///         Fully standalone: no admin, no owner, no state, immutable wiring.
///         Deployed after the core protocol since it needs the engine address.
contract USDGZapper is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Universal router command / v4 actions (same constants as UniswapV4Adapter).
    uint256 internal constant COMMAND_V4_SWAP = 0x10;
    uint256 internal constant ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 internal constant ACTION_SETTLE_ALL = 0x0c;
    uint256 internal constant ACTION_TAKE_ALL = 0x0f;
    address internal constant NATIVE_ETH = address(0);

    IUniversalRouterZ public immutable universalRouter;
    IPermit2Z public immutable permit2;
    IBoxEngineZ public immutable engine;
    address public immutable usdg;
    // ETH/USDG v4 pool key (currency0 = native ETH).
    uint24 public immutable poolFee;
    int24 public immutable poolTickSpacing;

    error InvalidAmount();
    error SwapFailed();

    event ZapMint(
        address indexed sender, address indexed recipient, uint256 indexed boxId, uint256 usdgIn, uint256 ethIn, uint256 boxOut
    );

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    constructor(address universalRouter_, address permit2_, address engine_, address usdg_, uint24 poolFee_, int24 poolTickSpacing_) {
        universalRouter = IUniversalRouterZ(universalRouter_);
        permit2 = IPermit2Z(permit2_);
        engine = IBoxEngineZ(engine_);
        usdg = usdg_;
        poolFee = poolFee_;
        poolTickSpacing = poolTickSpacing_;
    }

    /// @notice Swap `usdgIn` USDG to ETH and mint box `boxId` to `recipient`.
    /// @param minEthOut slippage floor for the USDG->ETH leg (from off-chain quote).
    /// @param minBoxOut slippage floor for the mint leg.
    /// @param minComponentOut per-component minimums aligned to component index (empty array allowed).
    function mintWithUSDG(
        uint256 boxId,
        uint256 usdgIn,
        uint256 minEthOut,
        uint256 minBoxOut,
        uint256[] calldata minComponentOut,
        address recipient
    ) external nonReentrant returns (uint256 boxOut) {
        if (usdgIn == 0 || recipient == address(0)) revert InvalidAmount();
        IERC20(usdg).safeTransferFrom(msg.sender, address(this), usdgIn);
        IERC20(usdg).forceApprove(address(permit2), usdgIn);
        permit2.approve(usdg, address(universalRouter), uint160(usdgIn), type(uint48).max);

        uint256 beforeBal = address(this).balance;
        universalRouter.execute(
            bytes.concat(bytes1(uint8(COMMAND_V4_SWAP))), _encodeUsdgToEth(usdgIn, minEthOut)
        );
        uint256 ethIn = address(this).balance - beforeBal;
        if (ethIn < minEthOut) revert SwapFailed();

        boxOut = engine.mint{value: ethIn}(boxId, minBoxOut, recipient, minComponentOut);
        emit ZapMint(msg.sender, recipient, boxId, usdgIn, ethIn, boxOut);

        // Return any dust the engine refunded (it shouldn't, but never strand funds).
        uint256 dust = address(this).balance - beforeBal;
        if (dust > 0) {
            (bool ok,) = msg.sender.call{value: dust}("");
            require(ok, "dust refund failed");
        }
    }

    function _encodeUsdgToEth(uint256 amountIn, uint256 minOut) internal view returns (bytes[] memory inputs) {
        bytes memory actions = bytes.concat(
            bytes1(uint8(ACTION_SWAP_EXACT_IN_SINGLE)), bytes1(uint8(ACTION_SETTLE_ALL)), bytes1(uint8(ACTION_TAKE_ALL))
        );
        ExactInputSingleParams memory p;
        p.poolKey = PoolKey({currency0: NATIVE_ETH, currency1: usdg, fee: poolFee, tickSpacing: poolTickSpacing, hooks: address(0)});
        p.zeroForOne = false; // USDG (currency1) -> ETH (currency0)
        p.amountIn = uint128(amountIn);
        p.amountOutMinimum = uint128(minOut);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(p);
        params[1] = abi.encode(usdg, amountIn);
        params[2] = abi.encode(NATIVE_ETH, minOut);
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    /// @dev Receives ETH from the universal router swap output.
    receive() external payable {}
}
