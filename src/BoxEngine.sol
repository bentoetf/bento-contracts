// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BoxToken} from "./BoxToken.sol";
import {BoxVault} from "./BoxVault.sol";
import {IBoxToken, IBoxVault, IAggregatorV3, IV2Router, IScaledUIAmountLite, ISwapAdapterLike} from "./interfaces.sol";

interface IBoxRegistryLike {
    function register(uint256 boxId, address engine) external;
}

/// @notice Bento Phase-1 engine: creates box vaults/tokens, zaps ETH into stock baskets, redeems to stocks/ETH, and records paused-stock claims.
contract BoxEngine is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 100;
    uint16 public constant DEFAULT_SANITY_BPS = 300;
    uint256 public constant GENESIS_BOX_USD = 100e18;

    struct Component {
        address token;
        uint16 weightBps;
        address router;
        address[] path; // V2 path, expected WETH -> component for phase 1.
        address feed; // USD feed for NAV/sanity; 0 skips.
    }

    struct Box {
        address boxToken;
        address vault;
        uint16 mintFeeBps;
        uint16 redeemFeeBps;
        uint128 tvlCapWei;
        bool mintPaused;
        bool exists;
        string metadataURI;
    }

    address public immutable admin;
    address public immutable registry;
    address public immutable ethUsdFeed;
    address public feeCollector;
    address public bento;
    bool public globalMintPaused;
    uint16 public sanityBps = DEFAULT_SANITY_BPS;
    uint256 public maxFeedAge = 24 hours;

    uint256 public nextBoxId = 1;
    mapping(uint256 => Box) public boxes;
    mapping(uint256 => uint128) public perTxMintCapWei;
    mapping(uint256 => Component[]) internal _components;
    mapping(uint256 => mapping(address => bool)) public isBoxComponent;
    mapping(uint256 => mapping(address => mapping(address => uint256))) public pendingClaims; // boxId -> user -> token -> amount
    mapping(uint256 => mapping(address => uint256)) public reservedClaims; // boxId -> token -> total vault tokens owed to claimants
    uint256[] public discountThresholds;
    uint16[] public discountBps;

    error NotAdmin();
    error NotFeeCollector();
    error BoxMissing();
    error BadWeights();
    error FeeTooHigh();
    error MintPaused();
    error TvlCapExceeded();
    error Slippage();
    error BadRoute();
    error BadTierConfig();
    error ComponentUnsweepable();
    error NoClaim();
    error TransferStillBlocked();
    error ZeroAddress();
    error SanityDeviation(address token, uint256 actualRawPerEth, uint256 expectedRawPerEth);
    error FeedStale(address feed, uint256 updatedAt, uint256 age);
    error PerTxMintCapExceeded();
    error BadComponentMins();

    event BoxCreated(
        uint256 indexed boxId,
        address indexed boxToken,
        address indexed vault,
        string name,
        string symbol,
        string metadataURI
    );
    event Minted(
        uint256 indexed boxId,
        address indexed payer,
        address indexed recipient,
        uint256 ethIn,
        uint256 feeEth,
        uint256 boxOut
    );
    event RedeemedForStocks(
        uint256 indexed boxId, address indexed user, address indexed to, uint256 boxIn, uint256 feeBox
    );
    event RedeemedForETH(
        uint256 indexed boxId, address indexed user, address indexed to, uint256 boxIn, uint256 feeBox, uint256 ethOut
    );
    event ClaimRecorded(uint256 indexed boxId, address indexed user, address indexed token, uint256 amount);
    event ClaimPaid(uint256 indexed boxId, address indexed user, address indexed token, address to, uint256 amount);
    event FeeCollectorSet(address indexed collector);
    event BentoSet(address indexed bento);
    event FeesSet(uint256 indexed boxId, uint16 mintFeeBps, uint16 redeemFeeBps);
    event TvlCapSet(uint256 indexed boxId, uint128 capWei);
    event MintPauseSet(uint256 indexed boxId, bool paused);
    event GlobalMintPauseSet(bool paused);
    event MetadataURISet(uint256 indexed boxId, string metadataURI);
    event DiscountTiersSet(uint256[] thresholds, uint16[] discounts);
    event ComponentRouteSet(uint256 indexed boxId, uint256 indexed idx, address router, address[] path);
    event RescueToken(address indexed token, address indexed to, uint256 amount);
    event SanityBpsSet(uint16 sanityBps);
    event MaxFeedAgeSet(uint256 maxFeedAge);
    event PerTxMintCapSet(uint256 indexed boxId, uint128 capWei);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier boxExists(uint256 boxId) {
        if (!boxes[boxId].exists) revert BoxMissing();
        _;
    }

    constructor(address admin_, address registry_, address feeCollector_, address bento_, address ethUsdFeed_) {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        registry = registry_;
        feeCollector = feeCollector_;
        bento = bento_;
        ethUsdFeed = ethUsdFeed_;
    }

    receive() external payable {}

    /// @notice Creates a new box token and one dedicated vault. Component weights must sum to 10000 bps.
    function createBox(
        string calldata name,
        string calldata symbol,
        Component[] calldata components_,
        uint16 mintFeeBps,
        uint16 redeemFeeBps,
        uint128 tvlCapWei,
        string calldata metadataURI
    ) external onlyAdmin returns (uint256 boxId, address boxToken, address vault) {
        if (mintFeeBps > MAX_FEE_BPS || redeemFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        uint256 weight;
        address[] memory tokens = new address[](components_.length);
        for (uint256 i; i < components_.length; ++i) {
            Component calldata c = components_[i];
            if (c.token == address(0) || c.router == address(0) || c.path.length < 2) revert BadRoute();
            if ((c.path[0] != address(0) && c.path[0] == c.token) || c.path[c.path.length - 1] != c.token) {
                revert BadRoute();
            }
            if (_isAdapterRouteCalldata(c.path) && (c.feed == address(0) || ethUsdFeed == address(0))) {
                revert BadRoute();
            }
            weight += c.weightBps;
            tokens[i] = c.token;
        }
        if (weight != BPS) revert BadWeights();

        boxId = nextBoxId++;
        boxToken = address(new BoxToken(name, symbol, address(this)));
        vault = address(new BoxVault(address(this), tokens));
        boxes[boxId] = Box(boxToken, vault, mintFeeBps, redeemFeeBps, tvlCapWei, false, true, metadataURI);
        for (uint256 i; i < components_.length; ++i) {
            _components[boxId].push(components_[i]);
            isBoxComponent[boxId][components_[i].token] = true;
        }
        if (registry != address(0)) {
            try IBoxRegistryLike(registry).register(boxId, address(this)) {} catch {}
        }
        emit BoxCreated(boxId, boxToken, vault, name, symbol, metadataURI);
    }

    /// @notice Mint box tokens by zapping native ETH into each configured stock component. Recipient may differ from payer.
    function mint(uint256 boxId, uint256 minBoxOut, address recipient)
        external
        payable
        nonReentrant
        boxExists(boxId)
        returns (uint256 boxOut)
    {
        return _mintBox(boxId, minBoxOut, _emptyMins(), recipient, msg.sender, msg.value);
    }

    /// @notice Mint box tokens with per-component token minimums aligned to component index.
    function mint(uint256 boxId, uint256 minBoxOut, address recipient, uint256[] calldata minComponentOut)
        external
        payable
        nonReentrant
        boxExists(boxId)
        returns (uint256 boxOut)
    {
        return _mintBox(boxId, minBoxOut, minComponentOut, recipient, msg.sender, msg.value);
    }

    /// @notice Backward-compatible mint to sender.
    function mint(uint256 boxId, uint256 minBoxOut)
        external
        payable
        nonReentrant
        boxExists(boxId)
        returns (uint256 boxOut)
    {
        return _mintBox(boxId, minBoxOut, _emptyMins(), msg.sender, msg.sender, msg.value);
    }

    /// @notice Mint to sender with per-component token minimums aligned to component index.
    function mint(uint256 boxId, uint256 minBoxOut, uint256[] calldata minComponentOut)
        external
        payable
        nonReentrant
        boxExists(boxId)
        returns (uint256 boxOut)
    {
        return _mintBox(boxId, minBoxOut, minComponentOut, msg.sender, msg.sender, msg.value);
    }

    /// @notice Redeem box tokens into underlying stock components. If a stock transfer reverts, a claim is recorded instead of reverting the whole redeem.
    function redeemForStocks(uint256 boxId, uint256 boxIn, address to) public nonReentrant boxExists(boxId) {
        if (to == address(0)) revert ZeroAddress();
        Box storage b = boxes[boxId];
        uint256 supplyBefore = IBoxToken(b.boxToken).totalSupply();
        uint256 feeBox = _feeFor(boxIn, b.redeemFeeBps, msg.sender);
        uint256 netBox = boxIn - feeBox;
        if (feeBox != 0 && feeCollector != address(0)) IBoxToken(b.boxToken).mint(feeCollector, feeBox);
        IBoxToken(b.boxToken).burn(msg.sender, boxIn);
        _redeemStocksFromVault(boxId, b.vault, supplyBefore, netBox, to);
        emit RedeemedForStocks(boxId, msg.sender, to, boxIn, feeBox);
    }

    /// @notice Redeem box tokens into ETH by swapping components. Paused components become stock claims.
    function redeemForETH(uint256 boxId, uint256 boxIn, uint256 minEthOut, address to)
        external
        nonReentrant
        boxExists(boxId)
        returns (uint256 ethOut)
    {
        return _redeemForETH(boxId, boxIn, minEthOut, _emptyMins(), to);
    }

    /// @notice Redeem box tokens into ETH with per-component ETH minimums aligned to component index.
    function redeemForETH(
        uint256 boxId,
        uint256 boxIn,
        uint256 minEthOut,
        uint256[] calldata minComponentEthOut,
        address to
    ) external nonReentrant boxExists(boxId) returns (uint256 ethOut) {
        return _redeemForETH(boxId, boxIn, minEthOut, minComponentEthOut, to);
    }

    function _redeemForETH(
        uint256 boxId,
        uint256 boxIn,
        uint256 minEthOut,
        uint256[] memory minComponentEthOut,
        address to
    ) internal returns (uint256 ethOut) {
        if (to == address(0)) revert ZeroAddress();
        Box storage b = boxes[boxId];
        uint256 supplyBefore = IBoxToken(b.boxToken).totalSupply();
        uint256 feeBox = _feeFor(boxIn, b.redeemFeeBps, msg.sender);
        uint256 netBox = boxIn - feeBox;
        if (feeBox != 0 && feeCollector != address(0)) IBoxToken(b.boxToken).mint(feeCollector, feeBox);
        IBoxToken(b.boxToken).burn(msg.sender, boxIn);

        Component[] storage comps = _components[boxId];
        if (minComponentEthOut.length != 0 && minComponentEthOut.length != comps.length) revert BadComponentMins();
        uint256 beforeEth = address(this).balance;
        for (uint256 i; i < comps.length; ++i) {
            Component storage c = comps[i];
            uint256 amount = (_availableBalance(boxId, c.token, b.vault) * netBox) / supplyBefore;
            uint256 legMinOut = _componentMin(minComponentEthOut, i);
            if (amount == 0) {
                if (legMinOut != 0) revert Slippage();
                continue;
            }
            try IBoxVault(b.vault).approveToken(c.token, c.router, amount) {
                try this.vaultSwapTokenForETH(
                    b.vault, c.token, c.router, _reversePath(c.path), amount, legMinOut
                ) returns (
                    uint256 legEthOut
                ) {
                    if (legEthOut < legMinOut) {
                        revert Slippage();
                    }
                } catch {
                    if (legMinOut != 0) revert Slippage();
                    _recordClaim(boxId, c.token, amount);
                }
            } catch {
                if (legMinOut != 0) revert Slippage();
                _recordClaim(boxId, c.token, amount);
            }
        }
        ethOut = address(this).balance - beforeEth;
        if (ethOut < minEthOut) revert Slippage();
        _sendETH(to, ethOut);
        emit RedeemedForETH(boxId, msg.sender, to, boxIn, feeBox, ethOut);
    }

    /// @notice External self-call adapter so router failures can be caught without reverting the whole ETH redeem.
    function vaultSwapTokenForETH(
        address vault,
        address token,
        address router,
        address[] calldata path,
        uint256 amount,
        uint256 minOut
    ) external returns (uint256 amountOut) {
        if (msg.sender != address(this)) revert NotAdmin();
        IBoxVault(vault).transferToken(token, address(this), amount);
        IERC20(token).forceApprove(router, amount);
        if (path.length == 2 && path[path.length - 1] == address(0)) {
            amountOut = ISwapAdapterLike(router).swapTokenToETH(token, amount, minOut, address(this));
        } else {
            uint256[] memory amounts =
                IV2Router(router).swapExactTokensForETH(amount, minOut, path, address(this), block.timestamp);
            amountOut = amounts[amounts.length - 1];
        }
    }

    /// @notice Claims a previously recorded paused/blocked component amount once transfers work again.
    function claimPending(uint256 boxId, address token, address to) external nonReentrant boxExists(boxId) {
        uint256 amount = pendingClaims[boxId][msg.sender][token];
        if (amount == 0) revert NoClaim();
        pendingClaims[boxId][msg.sender][token] = 0;
        reservedClaims[boxId][token] -= amount;
        try IBoxVault(boxes[boxId].vault).transferToken(token, to, amount) {
            emit ClaimPaid(boxId, msg.sender, token, to, amount);
        } catch {
            pendingClaims[boxId][msg.sender][token] = amount;
            reservedClaims[boxId][token] += amount;
            revert TransferStillBlocked();
        }
    }

    /// @notice Returns display NAV in wei per box token using component USD feeds and ETH/USD feed. Display only.
    function nav(uint256 boxId) external view boxExists(boxId) returns (uint256 navWeiPerToken) {
        uint256 usdPerBox = _navUsdPerBox1e18(boxId);
        if (usdPerBox == 0 || ethUsdFeed == address(0)) return 0;
        navWeiPerToken = (usdPerBox * 1e18) / _feed1e18(ethUsdFeed);
    }

    /// @notice Returns display NAV in 1e18 USD units per whole box token, using raw balance * uiMultiplier.
    function navUsdPerBox(uint256 boxId) external view boxExists(boxId) returns (uint256) {
        return _navUsdPerBox1e18(boxId);
    }

    /// @notice Canonical proof-of-reserves view: live raw vault balances for every component.
    function backing(uint256 boxId)
        external
        view
        boxExists(boxId)
        returns (address[] memory tokens, uint256[] memory balances)
    {
        Component[] storage comps = _components[boxId];
        tokens = new address[](comps.length);
        balances = new uint256[](comps.length);
        for (uint256 i; i < comps.length; ++i) {
            tokens[i] = comps[i].token;
            balances[i] = IERC20(comps[i].token).balanceOf(boxes[boxId].vault);
        }
    }

    /// @notice Proof-of-reserves detail: live raw balances, UI-adjusted balances, and component USD values.
    function backingDetailed(uint256 boxId)
        external
        view
        boxExists(boxId)
        returns (
            address[] memory tokens,
            uint256[] memory rawBalances,
            uint256[] memory uiBalances,
            uint256[] memory usdValues1e18
        )
    {
        Component[] storage comps = _components[boxId];
        tokens = new address[](comps.length);
        rawBalances = new uint256[](comps.length);
        uiBalances = new uint256[](comps.length);
        usdValues1e18 = new uint256[](comps.length);
        for (uint256 i; i < comps.length; ++i) {
            tokens[i] = comps[i].token;
            rawBalances[i] = IERC20(comps[i].token).balanceOf(boxes[boxId].vault);
            uiBalances[i] = _toUiAmount(comps[i].token, rawBalances[i]);
            if (comps[i].feed != address(0)) {
                usdValues1e18[i] = (uiBalances[i] * _feed1e18(comps[i].feed)) / (10 ** _decimals(comps[i].token));
            }
        }
    }

    /// @notice Quotes box output from pool reserves and current proportional issuance math.
    function quoteMint(uint256 boxId, uint256 ethIn) public view boxExists(boxId) returns (uint256 boxOut) {
        Box storage b = boxes[boxId];
        uint256 fee = _feeForView(ethIn, b.mintFeeBps, msg.sender);
        uint256 net = ethIn - fee;
        uint256 supply = IBoxToken(b.boxToken).totalSupply();
        if (supply == 0) return _genesisBoxOut(net);
        uint256 added;
        Component[] storage comps = _components[boxId];
        for (uint256 i; i < comps.length; ++i) {
            uint256 part = (net * comps[i].weightBps) / BPS;
            if (_isAdapterRoute(comps[i])) {
                added += part;
            } else {
                uint256[] memory amounts = IV2Router(comps[i].router).getAmountsOut(part, comps[i].path);
                added += _quoteTokenToEth(comps[i], amounts[amounts.length - 1]);
            }
        }
        return (supply * added) / quoteRedeemETH(boxId, supply);
    }

    /// @notice eth_call-only mint simulation that uses adapter quoters for adapter-routed components. May mutate/revert in static calls because V4 quoters are non-view.
    function simulateMint(uint256 boxId, uint256 ethIn) external boxExists(boxId) returns (uint256 boxOut) {
        Box storage b = boxes[boxId];
        uint256 fee = _feeForView(ethIn, b.mintFeeBps, msg.sender);
        uint256 net = ethIn - fee;
        uint256 supply = IBoxToken(b.boxToken).totalSupply();
        if (supply == 0) return _genesisBoxOut(net);
        uint256 added;
        Component[] storage comps = _components[boxId];
        for (uint256 i; i < comps.length; ++i) {
            uint256 part = (net * comps[i].weightBps) / BPS;
            if (_isAdapterRoute(comps[i])) {
                uint256 tokenOut = ISwapAdapterLike(comps[i].router).quoteETHToToken(comps[i].token, part);
                added += _quoteTokenToEth(comps[i], tokenOut);
            } else {
                uint256[] memory amounts = IV2Router(comps[i].router).getAmountsOut(part, comps[i].path);
                added += _quoteTokenToEth(comps[i], amounts[amounts.length - 1]);
            }
        }
        return (supply * added) / quoteRedeemETH(boxId, supply);
    }

    /// @notice Quotes ETH redemption from pool reserves for the supplied box amount.
    function quoteRedeemETH(uint256 boxId, uint256 boxIn) public view boxExists(boxId) returns (uint256 ethOut) {
        uint256 supply = IBoxToken(boxes[boxId].boxToken).totalSupply();
        if (supply == 0) return 0;
        Component[] storage comps = _components[boxId];
        for (uint256 i; i < comps.length; ++i) {
            uint256 amount = (_availableBalance(boxId, comps[i].token, boxes[boxId].vault) * boxIn) / supply;
            ethOut += _quoteTokenToEth(comps[i], amount);
        }
    }

    function components(uint256 boxId) external view returns (Component[] memory) {
        return _components[boxId];
    }

    function setFeeCollector(address collector) external onlyAdmin {
        feeCollector = collector;
        emit FeeCollectorSet(collector);
    }

    function setBento(address bento_) external onlyAdmin {
        bento = bento_;
        emit BentoSet(bento_);
    }

    function setFees(uint256 boxId, uint16 mintFeeBps, uint16 redeemFeeBps) external onlyAdmin boxExists(boxId) {
        if (mintFeeBps > MAX_FEE_BPS || redeemFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        boxes[boxId].mintFeeBps = mintFeeBps;
        boxes[boxId].redeemFeeBps = redeemFeeBps;
        emit FeesSet(boxId, mintFeeBps, redeemFeeBps);
    }

    function setTvlCap(uint256 boxId, uint128 cap) external onlyAdmin boxExists(boxId) {
        boxes[boxId].tvlCapWei = cap;
        emit TvlCapSet(boxId, cap);
    }

    function setPerTxMintCap(uint256 boxId, uint128 cap) external onlyAdmin boxExists(boxId) {
        perTxMintCapWei[boxId] = cap;
        emit PerTxMintCapSet(boxId, cap);
    }

    function setMintPaused(uint256 boxId, bool paused) external onlyAdmin boxExists(boxId) {
        boxes[boxId].mintPaused = paused;
        emit MintPauseSet(boxId, paused);
    }

    function setGlobalMintPaused(bool paused) external onlyAdmin {
        globalMintPaused = paused;
        emit GlobalMintPauseSet(paused);
    }

    function setMetadataURI(uint256 boxId, string calldata uri) external onlyAdmin boxExists(boxId) {
        boxes[boxId].metadataURI = uri;
        emit MetadataURISet(boxId, uri);
    }

    function setSanityBps(uint16 bps_) external onlyAdmin {
        if (bps_ > BPS) revert BadWeights();
        sanityBps = bps_;
        emit SanityBpsSet(bps_);
    }

    function setMaxFeedAge(uint256 age) external onlyAdmin {
        maxFeedAge = age;
        emit MaxFeedAgeSet(age);
    }

    function setDiscountTiers(uint256[] calldata thresholds, uint16[] calldata discounts) external onlyAdmin {
        if (thresholds.length != discounts.length) revert BadTierConfig();
        delete discountThresholds;
        delete discountBps;
        for (uint256 i; i < thresholds.length; ++i) {
            if (discounts[i] > BPS) revert BadTierConfig();
            discountThresholds.push(thresholds[i]);
            discountBps.push(discounts[i]);
        }
        emit DiscountTiersSet(thresholds, discounts);
    }

    function setComponentRoute(uint256 boxId, uint256 idx, address router, address[] calldata path)
        external
        onlyAdmin
        boxExists(boxId)
    {
        Component storage c = _components[boxId][idx];
        if (router == address(0) || path.length < 2 || path[path.length - 1] != c.token) revert BadRoute();
        if (_isAdapterRouteCalldata(path) && (c.feed == address(0) || ethUsdFeed == address(0))) revert BadRoute();
        c.router = router;
        c.path = path;
        emit ComponentRouteSet(boxId, idx, router, path);
    }

    function rescueToken(uint256 boxId, address token, address to) external onlyAdmin boxExists(boxId) {
        if (isBoxComponent[boxId][token]) revert ComponentUnsweepable();
        uint256 amount = IERC20(token).balanceOf(boxes[boxId].vault);
        IBoxVault(boxes[boxId].vault).sweepNonComponent(token, to);
        emit RescueToken(token, to, amount);
    }

    function _mintBox(
        uint256 boxId,
        uint256 minBoxOut,
        uint256[] memory minComponentOut,
        address recipient,
        address payer,
        uint256 ethIn
    ) internal returns (uint256 boxOut) {
        Box storage b = boxes[boxId];
        if (globalMintPaused || b.mintPaused) revert MintPaused();
        if (perTxMintCapWei[boxId] != 0 && ethIn > perTxMintCapWei[boxId]) revert PerTxMintCapExceeded();
        if (recipient == address(0)) revert ZeroAddress();
        uint256 fee = _feeFor(ethIn, b.mintFeeBps, payer);
        if (fee != 0 && feeCollector != address(0)) _sendETH(feeCollector, fee);
        uint256 net = ethIn - fee;

        uint256 supplyBefore = IBoxToken(b.boxToken).totalSupply();
        uint256 valueBefore = supplyBefore == 0 ? 0 : quoteRedeemETH(boxId, supplyBefore);
        uint256 valueAdded;
        uint256 remaining = net;
        Component[] storage comps = _components[boxId];
        if (minComponentOut.length != 0 && minComponentOut.length != comps.length) revert BadComponentMins();
        for (uint256 i; i < comps.length; ++i) {
            Component storage c = comps[i];
            uint256 part = (i == comps.length - 1) ? remaining : (net * c.weightBps) / BPS;
            remaining -= part;
            uint256 minOut = _componentMin(minComponentOut, i);
            uint256 beforeBal = IERC20(c.token).balanceOf(b.vault);
            if (_isAdapterRoute(c)) {
                ISwapAdapterLike(c.router).swapETHToToken{value: part}(c.token, minOut, b.vault);
            } else {
                IV2Router(c.router).swapExactETHForTokens{value: part}(minOut, c.path, b.vault, block.timestamp);
            }
            uint256 got = IERC20(c.token).balanceOf(b.vault) - beforeBal;
            if (got < minOut) revert Slippage();
            _checkExecutionSanity(c, part, got);
            valueAdded += _quoteTokenToEth(c, got);
        }

        if (supplyBefore == 0) boxOut = _genesisBoxOut(net);
        else boxOut = (supplyBefore * valueAdded) / valueBefore;
        if (boxOut < minBoxOut) revert Slippage();
        IBoxToken(b.boxToken).mint(recipient, boxOut);
        if (b.tvlCapWei != 0 && quoteRedeemETH(boxId, IBoxToken(b.boxToken).totalSupply()) > b.tvlCapWei) {
            revert TvlCapExceeded();
        }
        emit Minted(boxId, payer, recipient, ethIn, fee, boxOut);
    }

    function _redeemStocksFromVault(uint256 boxId, address vault, uint256 supplyBefore, uint256 netBox, address to)
        internal
    {
        Component[] storage comps = _components[boxId];
        for (uint256 i; i < comps.length; ++i) {
            uint256 amount = (_availableBalance(boxId, comps[i].token, vault) * netBox) / supplyBefore;
            if (amount == 0) continue;
            try IBoxVault(vault).transferToken(comps[i].token, to, amount) {}
            catch {
                _recordClaim(boxId, comps[i].token, amount);
            }
        }
    }

    /// @notice Vault balance minus tokens already reserved for pending claims.
    function _availableBalance(uint256 boxId, address token, address vault) internal view returns (uint256) {
        uint256 bal = IERC20(token).balanceOf(vault);
        uint256 reserved = reservedClaims[boxId][token];
        return bal > reserved ? bal - reserved : 0;
    }

    function _recordClaim(uint256 boxId, address token, uint256 amount) internal {
        pendingClaims[boxId][msg.sender][token] += amount;
        reservedClaims[boxId][token] += amount;
        emit ClaimRecorded(boxId, msg.sender, token, amount);
    }

    function _feeFor(uint256 amount, uint16 feeBps, address user) internal view returns (uint256) {
        return (amount * feeBps * (BPS - _discountFor(user))) / (uint256(BPS) * BPS);
    }

    function _feeForView(uint256 amount, uint16 feeBps, address user) internal view returns (uint256) {
        return (amount * feeBps * (BPS - _discountFor(user))) / (uint256(BPS) * BPS);
    }

    function _discountFor(address user) internal view returns (uint16 d) {
        if (bento == address(0)) return 0;
        uint256 bal = IERC20(bento).balanceOf(user);
        for (uint256 i; i < discountThresholds.length; ++i) {
            if (bal >= discountThresholds[i]) d = discountBps[i];
        }
    }

    function _genesisBoxOut(uint256 ethNet) internal view returns (uint256) {
        if (ethUsdFeed == address(0)) return ethNet;
        return (ethNet * _feed1e18Fresh(ethUsdFeed)) / GENESIS_BOX_USD;
    }

    function _emptyMins() internal pure returns (uint256[] memory mins) {
        mins = new uint256[](0);
    }

    function _componentMin(uint256[] memory mins, uint256 idx) internal pure returns (uint256) {
        return mins.length == 0 ? 0 : mins[idx];
    }

    function _quoteTokenToEth(Component storage c, uint256 tokenAmount) internal view returns (uint256) {
        if (tokenAmount == 0) return 0;
        if (_isAdapterRoute(c)) return _tokenAmountToEthViaFeeds(c, tokenAmount);
        address[] memory rev = _reversePath(c.path);
        uint256[] memory amounts = IV2Router(c.router).getAmountsOut(tokenAmount, rev);
        return amounts[amounts.length - 1];
    }

    function _isAdapterRoute(Component storage c) internal view returns (bool) {
        return c.path.length == 2 && c.path[0] == address(0);
    }

    function _isAdapterRouteCalldata(address[] calldata path) internal pure returns (bool) {
        return path.length == 2 && path[0] == address(0);
    }

    function _tokenAmountToEthViaFeeds(Component storage c, uint256 rawAmount) internal view returns (uint256) {
        if (c.feed == address(0) || ethUsdFeed == address(0)) return 0;
        uint256 uiAmount = _toUiAmount(c.token, rawAmount);
        uint256 usdValue = (uiAmount * _feed1e18(c.feed)) / (10 ** _decimals(c.token));
        return (usdValue * 1e18) / _feed1e18(ethUsdFeed);
    }

    function _checkExecutionSanity(Component storage c, uint256 ethIn, uint256 rawOut) internal view {
        if (c.feed == address(0) || ethUsdFeed == address(0) || ethIn == 0 || rawOut == 0) return;
        uint256 stockRawUsd = (_feed1e18Fresh(c.feed) * _uiMultiplier(c.token)) / 1e18;
        uint256 ethUsd = _feed1e18Fresh(ethUsdFeed);
        if (stockRawUsd == 0 || ethUsd == 0) return;
        uint256 actualRawPerEth = (rawOut * 1e18) / ethIn;
        uint256 expectedRawPerEth = (ethUsd * 1e18) / stockRawUsd;
        uint256 diff = actualRawPerEth > expectedRawPerEth
            ? actualRawPerEth - expectedRawPerEth
            : expectedRawPerEth - actualRawPerEth;
        if (diff * BPS > expectedRawPerEth * sanityBps) {
            revert SanityDeviation(c.token, actualRawPerEth, expectedRawPerEth);
        }
    }

    function _navUsdPerBox1e18(uint256 boxId) internal view returns (uint256) {
        uint256 supply = IBoxToken(boxes[boxId].boxToken).totalSupply();
        if (supply == 0) return 0;
        uint256 totalUsdValue;
        Component[] storage comps = _components[boxId];
        for (uint256 i; i < comps.length; ++i) {
            if (comps[i].feed == address(0)) continue;
            uint256 rawBal = _availableBalance(boxId, comps[i].token, boxes[boxId].vault);
            uint256 uiBal = _toUiAmount(comps[i].token, rawBal);
            totalUsdValue += (uiBal * _feed1e18(comps[i].feed)) / (10 ** _decimals(comps[i].token));
        }
        return (totalUsdValue * 1e18) / supply;
    }

    function _toUiAmount(address token, uint256 rawAmount) internal view returns (uint256) {
        return (rawAmount * _uiMultiplier(token)) / 1e18;
    }

    function _uiMultiplier(address token) internal view returns (uint256) {
        try IScaledUIAmountLite(token).uiMultiplier() returns (uint256 m) {
            return m == 0 ? 1e18 : m;
        } catch {
            return 1e18;
        }
    }

    function _feed1e18Fresh(address feed) internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) return 0;
        if (updatedAt != 0 && block.timestamp > updatedAt + maxFeedAge) {
            revert FeedStale(feed, updatedAt, block.timestamp - updatedAt);
        }
        uint8 d = IAggregatorV3(feed).decimals();
        return uint256(answer) * 1e18 / (10 ** d);
    }

    function _reversePath(address[] storage path) internal view returns (address[] memory rev) {
        rev = new address[](path.length);
        for (uint256 i; i < path.length; ++i) {
            rev[i] = path[path.length - 1 - i];
        }
    }

    function _feed1e18(address feed) internal view returns (uint256) {
        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) return 0;
        uint8 d = IAggregatorV3(feed).decimals();
        return uint256(answer) * 1e18 / (10 ** d);
    }

    function _decimals(address token) internal view returns (uint8) {
        try IERC20MetadataLite(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    function _sendETH(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "ETH_SEND_FAILED");
    }
}

interface IERC20MetadataLite {
    function decimals() external view returns (uint8);
}
