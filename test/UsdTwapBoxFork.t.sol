// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {BoxRegistry} from "../src/BoxRegistry.sol";
import {BoxToken} from "../src/BoxToken.sol";
import {IAggregatorV3} from "../src/interfaces.sol";

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

    BoxEngine engine;
    uint256 boxId;

    function setUp() public {
        if (vm.envOr("RUN_LIVE_FORK", uint256(0)) != 1) {
            vm.skip(true);
        }
        vm.createSelectFork("robinhood");

        BoxRegistry registry = new BoxRegistry(address(this));
        engine = new BoxEngine(address(this), address(registry), address(0), address(0), ETH_USD_FEED);
        registry.setRegistrar(address(engine));

        BoxEngine.Component[] memory comps = new BoxEngine.Component[](3);
        comps[0] = BoxEngine.Component({token: CASHCAT, weightBps: 3400, router: SUSHI_ROUTER, path: _p(CASHCAT), feed: CASHCAT_USD});
        comps[1] = BoxEngine.Component({token: PONS, weightBps: 3300, router: SUSHI_ROUTER, path: _p(PONS), feed: PONS_USD});
        comps[2] = BoxEngine.Component({token: TENDIES, weightBps: 3300, router: SUSHI_ROUTER, path: _p(TENDIES), feed: TENDIES_USD});
        (boxId,,) = engine.createBox("Meme TWAP Box", "MEMETWAP", comps, 30, 30, uint128(100 ether), "");
    }

    function _p(address token) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = WETH;
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
            assertApproxEqRel(feedPrice1e18, dexUsd1e18[i], 0.10e18, "feed vs dexscreener > 10%");
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
