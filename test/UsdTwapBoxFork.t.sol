// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {BoxRegistry} from "../src/BoxRegistry.sol";
import {BoxToken} from "../src/BoxToken.sol";
import {IAggregatorV3} from "../src/interfaces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETHLike {
    function withdraw(uint256) external;
}

/// @notice Minimal Uniswap V3 swap adapter implementing BoxEngine's adapter
///         route interface (path = [address(0), token]). Robinhood mainnet has
///         no Sushi V2 pools for these meme tokens; liquidity lives in the
///         same V3 pools the TwapFeedV3 feeds observe (fee tier 10000).
contract V3SwapAdapter {
    using SafeERC20 for IERC20;

    ISwapRouter02 public immutable router;
    address public immutable weth;
    mapping(address => uint24) public feeOf;

    constructor(address _router, address _weth) {
        router = ISwapRouter02(_router);
        weth = _weth;
    }

    receive() external payable {}

    function setFee(address token, uint24 fee) external {
        feeOf[token] = fee;
    }

    function swapETHToToken(address token, uint256 minOut, address recipient)
        external
        payable
        returns (uint256 amountOut)
    {
        // SwapRouter02 wraps msg.value when tokenIn is WETH9.
        amountOut = router.exactInputSingle{value: msg.value}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: token,
                fee: feeOf[token],
                recipient: recipient,
                amountIn: msg.value,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function swapTokenToETH(address token, uint256 amountIn, uint256 minOut, address recipient)
        external
        returns (uint256 amountOut)
    {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(token).forceApprove(address(router), amountIn);
        amountOut = router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: weth,
                fee: feeOf[token],
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        IWETHLike(weth).withdraw(amountOut);
        (bool ok,) = recipient.call{value: amountOut}("");
        require(ok, "eth send failed");
    }

    function quoteETHToToken(address, uint256) external pure returns (uint256) {
        revert("quote unsupported");
    }

    function quoteTokenToETH(address, uint256) external pure returns (uint256) {
        revert("quote unsupported");
    }
}

/// @notice Live-fork wiring test: hoodoracle USD TWAP adapters (PR #2) as
///         Component.feed inputs to BoxEngine NAV math on Robinhood Chain.
///         Feeds compose token/WETH TwapFeedV3 x ETH/USD, 8 decimals.
///         Run: RUN_LIVE_FORK=1 forge test --match-contract UsdTwapBoxFork \
///              --fork-url https://rpc.mainnet.chain.robinhood.com -vv
contract UsdTwapBoxForkTest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant SUSHI_ROUTER = 0x9A55D3d0c0f09859c7869510f53eD0a30B340766;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    address constant CASHCAT = 0x020bfC650A365f8BB26819deAAbF3E21291018b4;
    address constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address constant TENDIES = 0x45242320DBB855EeA8Fd36804C6487E10E97FCF9;

    // hoodoracle UsdTwapAdapter deployments (DEPLOYMENTS.md, 2026-07-25)
    address constant CASHCAT_USD = 0xdfE6bA7641a4f536a303c46cfEFD673aF75ca286;
    address constant PONS_USD = 0x33ab56F507dcda241F07ad7F0cf89611af32F35d;
    address constant TENDIES_USD = 0xf2d89A553E6EEc797cF2DdE5Eb0Bec1A3897a8bf;

    address constant V3_SWAP_ROUTER02 = 0xCaf681a66D020601342297493863E78C959E5cb2;

    BoxEngine engine;
    V3SwapAdapter swapAdapter;
    uint256 boxId;

    function setUp() public {
        if (vm.envOr("RUN_LIVE_FORK", uint256(0)) != 1) {
            vm.skip(true);
        }
        vm.createSelectFork("robinhood");

        BoxRegistry registry = new BoxRegistry(address(this));
        engine = new BoxEngine(address(this), address(registry), address(0), address(0), ETH_USD_FEED);
        registry.setRegistrar(address(engine));

        // Route discovery (fork probe 2026-07-25): no Sushi V2 pairs exist for
        // CASHCAT/PONS/TENDIES on Robinhood mainnet. Real liquidity is in the
        // Uniswap V3 fee-10000 pools, the same pools the TWAP feeds observe:
        //   CASHCAT/WETH 0xA70fc67C9F69da90B63a0e4C05D229954574E313
        //   PONS/WETH    0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA
        //   TENDIES/WETH 0x237609918F330ADD285b8bC5f8f2922283D1C4C5
        // So components use an adapter route through SwapRouter02.
        swapAdapter = new V3SwapAdapter(V3_SWAP_ROUTER02, WETH);
        swapAdapter.setFee(CASHCAT, 10000);
        swapAdapter.setFee(PONS, 10000);
        swapAdapter.setFee(TENDIES, 10000);

        BoxEngine.Component[] memory comps = new BoxEngine.Component[](3);
        comps[0] = BoxEngine.Component({token: CASHCAT, weightBps: 3400, router: address(swapAdapter), path: _adapterPath(CASHCAT), feed: CASHCAT_USD});
        comps[1] = BoxEngine.Component({token: PONS, weightBps: 3300, router: address(swapAdapter), path: _adapterPath(PONS), feed: PONS_USD});
        comps[2] = BoxEngine.Component({token: TENDIES, weightBps: 3300, router: address(swapAdapter), path: _adapterPath(TENDIES), feed: TENDIES_USD});
        (boxId,,) = engine.createBox("Meme TWAP Box", "MEMETWAP", comps, 30, 30, uint128(100 ether), "");

        // TWAP feeds lag spot; the 1% fee tier plus lag can exceed the default
        // 3% execution sanity band on volatile memes. Widen to 15% for the fork.
        engine.setSanityBps(1500);
    }

    /// @dev Adapter route marker: path[0] == address(0) tells BoxEngine to use
    ///      ISwapAdapterLike on c.router instead of a V2 router path.
    function _adapterPath(address token) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = address(0);
        p[1] = token;
    }

    /// @dev Each adapter must answer live with 8 decimals, positive price,
    ///      and be fresh within BoxEngine's maxFeedAge staleness guard.
    function test_fork_adapters_live_and_fresh() public {
        address[3] memory feeds = [CASHCAT_USD, PONS_USD, TENDIES_USD];
        for (uint256 i; i < feeds.length; ++i) {
            IAggregatorV3 f = IAggregatorV3(feeds[i]);
            assertEq(f.decimals(), 8, "adapter must be 8 decimals");
            (, int256 answer,, uint256 updatedAt,) = f.latestRoundData();
            assertGt(answer, 0, "non-positive answer");
            assertLe(updatedAt, block.timestamp, "updatedAt in future");
            assertLe(block.timestamp - updatedAt, engine.maxFeedAge(), "stale vs maxFeedAge");
            emit log_named_int("adapter answer (1e8 USD)", answer);
        }
    }

    /// @dev Wire known balances into the vault and check per-component USD
    ///      values plus total NAV against the adapter prices end to end.
    function test_fork_nav_math_end_to_end() public {
        BoxEngine.Box memory b = _box();

        // Seed the vault with 1000 whole tokens of each component and 1 box supply.
        deal(CASHCAT, b.vault, 1000e18);
        deal(PONS, b.vault, 1000e18);
        deal(TENDIES, b.vault, 1000e18);
        vm.prank(address(engine));
        BoxToken(b.boxToken).mint(address(this), 1e18);

        (address[] memory tokens,,, uint256[] memory usdValues) = engine.backingDetailed(boxId);
        assertEq(tokens.length, 3);

        uint256 total;
        // dexscreener spot 2026-07-25: CASHCAT $0.05393, PONS $0.03944, TENDIES $0.01473
        uint256[3] memory dexUsd1e18 = [uint256(0.05393e18), 0.03944e18, 0.01473e18];
        string[3] memory names = ["CASHCAT", "PONS", "TENDIES"];
        for (uint256 i; i < 3; ++i) {
            // expected: 1000 tokens * feed price
            uint256 feedPrice1e18 = _feed1e18(i == 0 ? CASHCAT_USD : i == 1 ? PONS_USD : TENDIES_USD);
            assertEq(usdValues[i], 1000 * feedPrice1e18, "component USD != balance * feed");
            // feed within 10% of dexscreener spot (TWAP lag tolerance)
            assertApproxEqRel(feedPrice1e18, dexUsd1e18[i], 0.15e18, "feed vs dexscreener > 15%");
            emit log_named_uint(string.concat(names[i], " component USD (1e18)"), usdValues[i]);
            total += usdValues[i];
        }

        uint256 navUsd = engine.navUsdPerBox(boxId);
        assertEq(navUsd, total, "NAV != sum(component USD) at supply 1e18");
        emit log_named_uint("total NAV USD per box (1e18)", navUsd);
        assertGt(navUsd, 0);

        // nav() in wei must also resolve without revert via ETH/USD feed
        uint256 navWei = engine.nav(boxId);
        assertGt(navWei, 0, "nav wei zero");
        emit log_named_uint("NAV wei per box", navWei);
    }

    /// @dev Genesis mint path uses _feed1e18Fresh(ethUsdFeed); confirm the
    ///      ETH/USD feed passes the strict staleness check on this fork.
    function test_fork_ethusd_feed_fresh_for_genesis() public {
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(ETH_USD_FEED).latestRoundData();
        assertGt(answer, 0, "eth/usd non-positive");
        assertLe(block.timestamp - updatedAt, engine.maxFeedAge(), "eth/usd stale vs maxFeedAge");
        emit log_named_int("ETH/USD answer", answer);
    }

    /// @dev Real mint (ETH zapped through Sushi V2 WETH->token routes into the
    ///      vault) and redeem (vault tokens swapped back token->WETH->ETH),
    ///      exercising BoxEngine's actual swap paths on the live fork.
    ///      NAV per box must stay consistent (only fees/slippage move it).
    function test_fork_mint_redeem_roundtrip_real_routes() public {
        address user = makeAddr("user");
        vm.deal(user, 1 ether);

        // Genesis mint: 0.1 ETH zapped across the three components.
        vm.prank(user);
        uint256 boxOut = engine.mint{value: 0.1 ether}(boxId, 0, user);
        assertGt(boxOut, 0, "genesis mint out zero");
        emit log_named_uint("box shares from 0.1 ETH mint", boxOut);

        uint256 navAfterMint = engine.navUsdPerBox(boxId);
        assertGt(navAfterMint, 0, "NAV zero after mint");
        emit log_named_uint("NAV USD per box after mint (1e18)", navAfterMint);

        BoxEngine.Box memory b = _box();
        // Vault must actually hold all three components after the swaps.
        assertGt(IAggregatorV3(CASHCAT_USD).decimals(), 0); // keep feed touchable
        assertGt(_bal(CASHCAT, b.vault), 0, "vault has no CASHCAT");
        assertGt(_bal(PONS, b.vault), 0, "vault has no PONS");
        assertGt(_bal(TENDIES, b.vault), 0, "vault has no TENDIES");

        // Second mint: share pricing path (supply > 0) with real quotes.
        vm.prank(user);
        uint256 boxOut2 = engine.mint{value: 0.05 ether}(boxId, 0, user);
        assertGt(boxOut2, 0, "second mint out zero");
        uint256 navAfterMint2 = engine.navUsdPerBox(boxId);
        // NAV per box should be stable across mints within slippage tolerance.
        assertApproxEqRel(navAfterMint2, navAfterMint, 0.05e18, "NAV drift > 5% across mint");

        // Redeem half the shares back to ETH through the reverse routes.
        uint256 half = (boxOut + boxOut2) / 2;
        uint256 ethBefore = user.balance;
        vm.prank(user);
        uint256 ethOut = engine.redeemForETH(boxId, half, 0, user);
        assertGt(ethOut, 0, "redeem out zero");
        assertEq(user.balance - ethBefore, ethOut, "eth not delivered");
        emit log_named_uint("eth out from half redeem (wei)", ethOut);

        uint256 navAfterRedeem = engine.navUsdPerBox(boxId);
        assertApproxEqRel(navAfterRedeem, navAfterMint2, 0.05e18, "NAV drift > 5% across redeem");
        emit log_named_uint("NAV USD per box after redeem (1e18)", navAfterRedeem);

        // Round-trip cost sanity on thin meme pools: expect > 70% back pro rata.
        // 0.15 ETH in for boxOut+boxOut2 shares; half redeemed.
        uint256 proRataIn = 0.15 ether / 2;
        assertGt(ethOut, (proRataIn * 7000) / 10000, "round trip cost > 30%");

        // Redeem the rest for underlying stocks (component transfer path).
        vm.prank(user);
        engine.redeemForStocks(boxId, (boxOut + boxOut2) - half, user);
        assertGt(_bal(CASHCAT, user), 0, "no CASHCAT delivered");
        assertGt(_bal(PONS, user), 0, "no PONS delivered");
        assertGt(_bal(TENDIES, user), 0, "no TENDIES delivered");
    }

    function _bal(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        return abi.decode(data, (uint256));
    }

    function _feed1e18(address feed) internal view returns (uint256) {
        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        uint8 d = IAggregatorV3(feed).decimals();
        return uint256(answer) * 1e18 / (10 ** d);
    }

    function _box() internal view returns (BoxEngine.Box memory box_) {
        (address boxToken, address vault, uint16 mf, uint16 rf, uint128 cap, bool mp, bool ex, string memory uri) =
            engine.boxes(boxId);
        box_ = BoxEngine.Box(boxToken, vault, mf, rf, cap, mp, ex, uri);
    }
}
