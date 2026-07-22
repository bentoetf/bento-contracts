// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBoxToken, IV2Router} from "./interfaces.sol";

interface IEngineRedeemer {
    function redeemForETH(uint256 boxId, uint256 boxIn, uint256 minEthOut, address to) external returns (uint256);
    function boxes(uint256 boxId)
        external
        view
        returns (address boxToken, address vault, uint16, uint16, uint128, bool, bool, string memory);
}

/// @notice Receives Bento engine fees, redeems fee boxes, and buys BENTO to burn through Sushi V2.
contract FeeCollector is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable admin;
    address public engine;
    address public bento;
    address public sushiRouter;
    address[] public buybackPath;
    mapping(address => bool) public keepers;
    uint256 public minDelay = 30 minutes;
    uint256 public maxEthPerBuyback = 5 ether;
    uint256 public lastBuybackAt;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    error NotAdmin();
    error TooSoon();
    error NoPath();
    error ZeroAddress();
    error NotKeeper();

    event EngineSet(address indexed engine);
    event BuybackConfigSet(address indexed router, address[] path, uint256 minDelay, uint256 maxEthPerBuyback);
    event KeeperSet(address indexed keeper, bool enabled);
    event FeeBoxesRedeemed(uint256 indexed boxId, uint256 boxIn, uint256 ethOut);
    event BuybackAndBurn(address indexed keeper, uint256 ethIn, uint256 bentoOut);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }
    modifier onlyKeeper() {
        if (msg.sender != admin && !keepers[msg.sender]) revert NotKeeper();
        _;
    }

    constructor(address admin_, address engine_, address bento_, address sushiRouter_, address[] memory buybackPath_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        engine = engine_;
        bento = bento_;
        sushiRouter = sushiRouter_;
        keepers[admin_] = true;
        buybackPath = buybackPath_;
    }

    receive() external payable {}

    /// @notice Sets the engine address allowed/used for fee-box redemption.
    function setEngine(address engine_) external onlyAdmin {
        engine = engine_;
        emit EngineSet(engine_);
    }

    /// @notice Enables/disables keepers allowed to redeem fee box tokens into ETH.
    function setKeeper(address keeper, bool enabled) external onlyAdmin {
        keepers[keeper] = enabled;
        emit KeeperSet(keeper, enabled);
    }

    /// @notice Updates buyback route and rate limits.
    function setBuybackConfig(address router, address[] calldata path, uint256 delay_, uint256 maxEth_)
        external
        onlyAdmin
    {
        sushiRouter = router;
        delete buybackPath;
        for (uint256 i; i < path.length; ++i) {
            buybackPath.push(path[i]);
        }
        minDelay = delay_;
        maxEthPerBuyback = maxEth_;
        emit BuybackConfigSet(router, path, delay_, maxEth_);
    }

    /// @notice Redeems accumulated box-token fees into ETH through the engine.
    function redeemFeeBoxes(uint256 boxId, uint256 minEthOut)
        external
        nonReentrant
        onlyKeeper
        returns (uint256 ethOut)
    {
        (address boxToken,,,,,,,) = IEngineRedeemer(engine).boxes(boxId);
        uint256 amount = IERC20(boxToken).balanceOf(address(this));
        IERC20(boxToken).forceApprove(engine, amount);
        ethOut = IEngineRedeemer(engine).redeemForETH(boxId, amount, minEthOut, address(this));
        emit FeeBoxesRedeemed(boxId, amount, ethOut);
    }

    /// @notice Swaps held ETH into BENTO via Sushi and sends output to the dead address. Keeper-only and rate-limited.
    function buybackAndBurn(uint256 minBentoOut) external nonReentrant onlyKeeper returns (uint256 bentoOut) {
        if (block.timestamp < lastBuybackAt + minDelay) revert TooSoon();
        if (sushiRouter == address(0) || buybackPath.length < 2) revert NoPath();
        uint256 ethIn = address(this).balance;
        if (ethIn > maxEthPerBuyback) ethIn = maxEthPerBuyback;
        uint256 beforeBal = IERC20(bento).balanceOf(DEAD);
        lastBuybackAt = block.timestamp;
        IV2Router(sushiRouter).swapExactETHForTokens{value: ethIn}(minBentoOut, buybackPath, DEAD, block.timestamp);
        bentoOut = IERC20(bento).balanceOf(DEAD) - beforeBal;
        emit BuybackAndBurn(msg.sender, ethIn, bentoOut);
    }
}
