// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {BentoToken} from "../src/BentoToken.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {BoxVault} from "../src/BoxVault.sol";
import {BoxRegistry} from "../src/BoxRegistry.sol";
import {IBoxToken} from "../src/interfaces.sol";
import {MockERC20, MockFeed, MockRouter, MockAdapter} from "./Mocks.sol";

contract BoxEngineTest is Test {
    address admin = address(0xA11CE);
    address user = address(0xB0B);
    address devWallet = address(0xD3F);
    address lpSeeder = address(0x1A11CEED);
    address weth = address(0xBEEF);
    MockRouter router;
    MockFeed ethFeed;
    BentoToken bento;
    FeeCollector collector;
    BoxEngine engine;
    MockERC20[7] stocks;
    MockFeed[7] feeds;

    function setUp() public {
        router = new MockRouter(weth);
        vm.deal(address(router), 1_000 ether);
        ethFeed = new MockFeed(4000e8, 8);
        bento = new BentoToken(admin, admin, devWallet);
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(bento);
        collector = new FeeCollector(admin, address(0), address(bento), address(router), path);
        engine = new BoxEngine(admin, address(0), address(collector), address(bento), address(ethFeed));
        vm.prank(admin);
        collector.setEngine(address(engine));
        for (uint256 i; i < 7; ++i) {
            stocks[i] = new MockERC20(string.concat("Stock", vm.toString(i)), string.concat("S", vm.toString(i)), 18);
            feeds[i] = new MockFeed(int256(uint256(4000e8) / (40 + i)), 8);
            router.setRate(address(stocks[i]), (40 + i) * 1e18); // token units per ETH
        }
        router.setRate(address(bento), 1_000_000e18);
        vm.prank(admin);
        bento.transfer(address(router), 10_000_000 ether);
        vm.deal(user, 100 ether);
    }

    function _createMag7() internal returns (uint256 boxId) {
        BoxEngine.Component[] memory comps = new BoxEngine.Component[](7);
        for (uint256 i; i < 7; ++i) {
            address[] memory path = new address[](2);
            path[0] = weth;
            path[1] = address(stocks[i]);
            comps[i] = BoxEngine.Component({
                token: address(stocks[i]),
                weightBps: i == 6 ? uint16(1432) : uint16(1428),
                router: address(router),
                path: path,
                feed: address(feeds[i])
            });
        }
        vm.prank(admin);
        (boxId,,) = engine.createBox("MAG7 Bento Box", "MAG7", comps, 30, 30, 25 ether, "ipfs://mag7");
    }

    function testLifecycleMintRedeemStocksAndETH() public {
        uint256 boxId = _createMag7();
        vm.prank(user);
        uint256 boxOut = engine.mint{value: 1 ether}(boxId, 0, user);
        assertGt(boxOut, 0);
        (address boxToken, address vault,,,,,,) = engine.boxes(boxId);
        assertEq(IBoxToken(boxToken).balanceOf(user), boxOut);
        (address[] memory tokens, uint256[] memory balances) = engine.backing(boxId);
        assertEq(tokens.length, 7);
        for (uint256 i; i < balances.length; ++i) {
            assertGt(balances[i], 0);
        }

        vm.prank(user);
        engine.redeemForStocks(boxId, boxOut / 2, user);
        assertGt(stocks[0].balanceOf(user), 0);

        uint256 remaining = IBoxToken(boxToken).balanceOf(user);
        vm.prank(user);
        uint256 ethOut = engine.redeemForETH(boxId, remaining, 0, user);
        assertGt(ethOut, 0);
        assertLt(stocks[0].balanceOf(vault), balances[0] / 100); // only protocol-favoring redeem-fee dust remains
    }

    function testGenesisHundredDollarScaleAndSecondMintProportional() public {
        uint256 boxId = _createMag7();
        vm.prank(user);
        uint256 first = engine.mint{value: 1 ether}(boxId, 0, user);
        // 1 ETH at $4000, less 30 bps fee, gives 39.88 $100-box tokens.
        assertApproxEqAbs(first, 39.88 ether, 0.001 ether);
        vm.prank(user);
        uint256 second = engine.mint{value: 1 ether}(boxId, 0, user);
        assertApproxEqRel(second, first, 0.02e18);
    }

    function testPausedComponentRedeemRecordsClaimThenClaimAfterUnpause() public {
        uint256 boxId = _createMag7();
        vm.prank(user);
        uint256 boxOut = engine.mint{value: 1 ether}(boxId, 0, user);
        stocks[0].setPaused(true);
        vm.prank(user);
        engine.redeemForStocks(boxId, boxOut / 2, user);
        uint256 claim = engine.pendingClaims(boxId, user, address(stocks[0]));
        assertGt(claim, 0);
        stocks[0].setPaused(false);
        vm.prank(user);
        engine.claimPending(boxId, address(stocks[0]), user);
        assertEq(engine.pendingClaims(boxId, user, address(stocks[0])), 0);
        assertGt(stocks[0].balanceOf(user), 0);
    }

    function testPendingClaimsDoNotDoubleCountForLaterRedeemers() public {
        uint256 boxId = _createMag7();
        address user2 = address(0xCAFE);
        vm.deal(user2, 100 ether);
        vm.prank(user);
        uint256 out1 = engine.mint{value: 1 ether}(boxId, 0, user);
        vm.prank(user2);
        uint256 out2 = engine.mint{value: 1 ether}(boxId, 0, user2);

        (, address vault,,,,,,) = engine.boxes(boxId);
        stocks[0].setPaused(true);

        // user redeems all their boxes while stock0 is paused -> claim recorded, tokens stay in vault.
        vm.prank(user);
        engine.redeemForStocks(boxId, out1, user);
        uint256 claim1 = engine.pendingClaims(boxId, user, address(stocks[0]));
        assertGt(claim1, 0);
        assertEq(engine.reservedClaims(boxId, address(stocks[0])), claim1);

        // user2 redeems all theirs, still paused. Their pro-rata share must exclude user's reserved claim.
        vm.prank(user2);
        engine.redeemForStocks(boxId, out2, user2);
        uint256 claim2 = engine.pendingClaims(boxId, user2, address(stocks[0]));
        assertGt(claim2, 0);

        // Total promised must be covered by what the vault actually holds.
        uint256 vaultBal = stocks[0].balanceOf(vault);
        assertLe(claim1 + claim2, vaultBal);

        // Both claims must be fully payable after unpause.
        stocks[0].setPaused(false);
        vm.prank(user);
        engine.claimPending(boxId, address(stocks[0]), user);
        vm.prank(user2);
        engine.claimPending(boxId, address(stocks[0]), user2);
        assertEq(stocks[0].balanceOf(user), claim1);
        assertEq(stocks[0].balanceOf(user2), claim2);
        assertEq(engine.reservedClaims(boxId, address(stocks[0])), 0);
    }

    function testMultiplierRebaseUsesLiveBalances() public {
        uint256 boxId = _createMag7();
        vm.prank(user);
        uint256 boxOut = engine.mint{value: 1 ether}(boxId, 0, user);
        (, uint256[] memory beforeBalances) = engine.backing(boxId);
        stocks[0].setMultiplier(2e18);
        (, uint256[] memory afterBalances) = engine.backing(boxId);
        assertEq(afterBalances[0], beforeBalances[0] * 2);
        vm.prank(user);
        engine.redeemForStocks(boxId, boxOut / 10, user);
        assertGt(stocks[0].balanceOf(user), beforeBalances[0] / 10);
    }

    function testFeeCapsDiscountsRescueAndPause() public {
        uint256 boxId = _createMag7();
        vm.startPrank(admin);
        vm.expectRevert(BoxEngine.FeeTooHigh.selector);
        engine.setFees(boxId, 101, 0);
        uint256[] memory th = new uint256[](1);
        th[0] = 100 ether;
        uint16[] memory ds = new uint16[](1);
        ds[0] = 5_000;
        engine.setDiscountTiers(th, ds);
        engine.setGlobalMintPaused(true);
        vm.stopPrank();
        vm.prank(user);
        vm.expectRevert(BoxEngine.MintPaused.selector);
        engine.mint{value: 1 ether}(boxId, 0, user);
        vm.prank(admin);
        engine.setGlobalMintPaused(false);
        vm.prank(admin);
        bento.transfer(user, 100 ether);
        vm.prank(user);
        engine.mint{value: 1 ether}(boxId, 0, user);
        assertApproxEqAbs(address(collector).balance, 0.0015 ether, 1);

        MockERC20 junk = new MockERC20("Junk", "J", 18);
        (, address vault,,,,,,) = engine.boxes(boxId);
        junk.mint(vault, 1 ether);
        vm.prank(admin);
        engine.rescueToken(boxId, address(junk), admin);
        assertEq(junk.balanceOf(admin), 1 ether);
        vm.prank(admin);
        vm.expectRevert(BoxEngine.ComponentUnsweepable.selector);
        engine.rescueToken(boxId, address(stocks[0]), admin);
    }

    function testBuybackAndBurnRateLimit() public {
        uint256 boxId = _createMag7();
        vm.prank(user);
        engine.mint{value: 1 ether}(boxId, 0, user);
        uint256 beforeDead = bento.balanceOf(collector.DEAD());
        vm.warp(block.timestamp + collector.minDelay());
        vm.expectRevert(FeeCollector.NotKeeper.selector);
        vm.prank(user);
        collector.buybackAndBurn(0);
        vm.prank(admin);
        collector.buybackAndBurn(0);
        assertGt(bento.balanceOf(collector.DEAD()), beforeDead);
        vm.expectRevert(FeeCollector.TooSoon.selector);
        vm.prank(admin);
        collector.buybackAndBurn(0);
    }

    function testBentoHasNoOwnerMintPauseSelectors() public {
        (bool ownerOk,) = address(bento).staticcall(abi.encodeWithSignature("owner()"));
        (bool pauseOk,) = address(bento).call(abi.encodeWithSignature("pause()"));
        (bool mintOk,) = address(bento).call(abi.encodeWithSignature("mint(address,uint256)", user, 1));
        assertFalse(ownerOk);
        assertFalse(pauseOk);
        assertFalse(mintOk);
    }

    function testBentoPairTaxBuySellWalletExemptCapAndLock() public {
        address buyer = address(0xB00B1E);
        address seller = address(0x5E11E2);
        address newDev = address(0xD3F2);
        uint256 amount = 1_000 ether;

        vm.startPrank(admin);
        bento.setTaxedPair(address(router), true);
        bento.setTaxExempt(lpSeeder, true);
        vm.expectRevert(BentoToken.TaxTooHigh.selector);
        bento.setTaxBps(301);
        bento.setDevWallet(newDev);
        vm.stopPrank();

        // Buy: pair -> wallet is taxed and dev wallet receives 3% in BENTO.
        vm.prank(address(router));
        bento.transfer(buyer, amount);
        assertEq(bento.balanceOf(buyer), 970 ether);
        assertEq(bento.balanceOf(newDev), 30 ether);

        // Plain wallet -> wallet transfer is tax-free.
        vm.prank(buyer);
        bento.transfer(seller, 100 ether);
        assertEq(bento.balanceOf(seller), 100 ether);
        assertEq(bento.balanceOf(newDev), 30 ether);

        // Sell: wallet -> pair is taxed.
        vm.prank(seller);
        bento.transfer(address(router), 100 ether);
        assertEq(bento.balanceOf(newDev), 33 ether);

        // Exempt on either side disables tax, including LP seeding wallet.
        vm.prank(address(router));
        bento.transfer(lpSeeder, amount);
        assertEq(bento.balanceOf(lpSeeder), amount);
        assertEq(bento.balanceOf(newDev), 33 ether);
        vm.prank(lpSeeder);
        bento.transfer(address(router), amount);
        assertEq(bento.balanceOf(newDev), 33 ether);

        // Admin can lower/restore up to cap until permanently locked.
        vm.startPrank(admin);
        bento.setTaxBps(100);
        assertEq(bento.taxBps(), 100);
        bento.setTaxBps(300);
        bento.lockTaxForever();
        assertEq(bento.taxBps(), 0);
        assertTrue(bento.taxLockedForever());
        vm.expectRevert(BentoToken.TaxLocked.selector);
        bento.setTaxBps(1);
        vm.stopPrank();

        uint256 devBefore = bento.balanceOf(newDev);
        vm.prank(address(router));
        bento.transfer(buyer, amount);
        assertEq(bento.balanceOf(newDev), devBefore);
    }

    function testBuybackAndBurnUntaxedWhenCollectorAndDeadExempt() public {
        uint256 boxId = _createMag7();
        vm.startPrank(admin);
        bento.setTaxedPair(address(router), true);
        bento.setTaxExempt(address(collector), true);
        bento.setTaxExempt(collector.DEAD(), true);
        vm.stopPrank();

        vm.prank(user);
        engine.mint{value: 1 ether}(boxId, 0, user);

        uint256 beforeDead = bento.balanceOf(collector.DEAD());
        uint256 beforeDev = bento.balanceOf(devWallet);
        uint256 feeEth = address(collector).balance;
        uint256 expectedBento = feeEth * router.tokensPerEth(address(bento)) / 1e18;
        vm.warp(block.timestamp + collector.minDelay());
        vm.prank(admin);
        uint256 bentoOut = collector.buybackAndBurn(0);
        assertEq(bentoOut, expectedBento);
        assertEq(bento.balanceOf(collector.DEAD()) - beforeDead, expectedBento);
        assertEq(bento.balanceOf(devWallet), beforeDev);
    }

    function testSanityBoundStaleFeedAndPerTxCap() public {
        uint256 boxId = _createMag7();
        vm.prank(admin);
        engine.setPerTxMintCap(boxId, 2 ether);
        vm.prank(user);
        vm.expectRevert(BoxEngine.PerTxMintCapExceeded.selector);
        engine.mint{value: 3 ether}(boxId, 0, user);

        router.setRate(address(stocks[0]), 20e18);
        vm.prank(user);
        vm.expectRevert();
        engine.mint{value: 1 ether}(boxId, 0, user);
        router.setRate(address(stocks[0]), 40e18);
        vm.prank(user);
        engine.mint{value: 1 ether}(boxId, 0, user);

        vm.warp(block.timestamp + 3 days);
        feeds[0].setUpdatedAt(block.timestamp - 2 days);
        vm.prank(user);
        vm.expectRevert();
        engine.mint{value: 1 ether}(boxId, 0, user);

        (address boxToken,,,,,,,) = engine.boxes(boxId);
        uint256 bal = IBoxToken(boxToken).balanceOf(user);
        vm.prank(user);
        engine.redeemForStocks(boxId, bal / 2, user);
    }

    function testGenesisMintUsesFreshEthUsdFeed() public {
        uint256 boxId = _createMag7();
        vm.warp(block.timestamp + 3 days);
        ethFeed.setUpdatedAt(block.timestamp - 2 days);
        vm.prank(user);
        vm.expectRevert();
        engine.mint{value: 1 ether}(boxId, 0, user);
    }

    function testMintPerComponentMinOutRevertsBadLegAndLength() public {
        uint256 boxId = _createMag7();
        uint256[] memory badLength = new uint256[](1);
        vm.prank(user);
        vm.expectRevert(BoxEngine.BadComponentMins.selector);
        engine.mint{value: 1 ether}(boxId, 0, user, badLength);

        uint256[] memory minComponentOut = new uint256[](7);
        minComponentOut[0] = 6 ether; // first leg receives ~5.69 stock0 with the default rate/fee split.
        vm.prank(user);
        vm.expectRevert();
        engine.mint{value: 1 ether}(boxId, 0, user, minComponentOut);
    }

    function testRedeemForETHPerComponentMinOutRevertsBadLegAndLength() public {
        uint256 boxId = _createMag7();
        vm.prank(user);
        uint256 boxOut = engine.mint{value: 1 ether}(boxId, 0, user);

        uint256[] memory badLength = new uint256[](1);
        vm.prank(user);
        vm.expectRevert(BoxEngine.BadComponentMins.selector);
        engine.redeemForETH(boxId, boxOut / 10, 0, badLength, user);

        uint256[] memory minComponentEthOut = new uint256[](7);
        minComponentEthOut[0] = 1 ether; // impossible for a single 1/7 redeem leg.
        vm.prank(user);
        vm.expectRevert(BoxEngine.Slippage.selector);
        engine.redeemForETH(boxId, boxOut / 10, 0, minComponentEthOut, user);
    }

    function testBackwardCompatibleMintAndRedeemOverloadsStillWork() public {
        uint256 boxId = _createMag7();
        vm.prank(user);
        uint256 boxOut = engine.mint{value: 1 ether}(boxId, 0);
        assertGt(boxOut, 0);
        vm.prank(user);
        uint256 ethOut = engine.redeemForETH(boxId, boxOut / 2, 0, user);
        assertGt(ethOut, 0);
    }

    function testNavUsdAndBackingDetailedUseFormula() public {
        uint256 boxId = _createMag7();
        vm.prank(user);
        engine.mint{value: 1 ether}(boxId, 0, user);
        uint256 navUsd = engine.navUsdPerBox(boxId);
        assertApproxEqAbs(navUsd, 100e18, 1e18);
        (
            address[] memory tokens,
            uint256[] memory rawBalances,
            uint256[] memory uiBalances,
            uint256[] memory usdValues
        ) = engine.backingDetailed(boxId);
        assertEq(tokens.length, 7);
        assertEq(rawBalances.length, 7);
        assertEq(uiBalances.length, 7);
        assertEq(usdValues.length, 7);
        assertGt(usdValues[0], 0);
    }

    function testRegistryWiringRegistersCreatedBox() public {
        BoxRegistry registry = new BoxRegistry(admin);
        BoxEngine wired = new BoxEngine(admin, address(registry), address(collector), address(bento), address(ethFeed));
        vm.prank(admin);
        registry.setRegistrar(address(wired));
        BoxEngine.Component[] memory comps = new BoxEngine.Component[](1);
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(stocks[0]);
        comps[0] = BoxEngine.Component({
            token: address(stocks[0]), weightBps: 10_000, router: address(router), path: path, feed: address(feeds[0])
        });
        vm.prank(admin);
        (uint256 boxId,,) = wired.createBox("One", "ONE", comps, 30, 30, 15 ether, "");
        assertEq(registry.engineOf(boxId), address(wired));
    }

    function testAdapterRoutesRequireFeedsAndEthUsdOnCreateAndRouteUpdate() public {
        MockAdapter adapter = new MockAdapter();
        adapter.setRate(address(stocks[0]), 40e18);
        address[] memory adapterPath = new address[](2);
        adapterPath[0] = address(0);
        adapterPath[1] = address(stocks[0]);
        BoxEngine.Component[] memory comps = new BoxEngine.Component[](1);
        comps[0] = BoxEngine.Component({
            token: address(stocks[0]), weightBps: 10_000, router: address(adapter), path: adapterPath, feed: address(0)
        });
        vm.prank(admin);
        vm.expectRevert(BoxEngine.BadRoute.selector);
        engine.createBox("Bad", "BAD", comps, 30, 30, 15 ether, "");

        BoxEngine noEthFeed = new BoxEngine(admin, address(0), address(collector), address(bento), address(0));
        comps[0] = BoxEngine.Component({
            token: address(stocks[0]),
            weightBps: 10_000,
            router: address(adapter),
            path: adapterPath,
            feed: address(feeds[0])
        });
        vm.prank(admin);
        vm.expectRevert(BoxEngine.BadRoute.selector);
        noEthFeed.createBox("Bad", "BAD", comps, 30, 30, 15 ether, "");

        uint256 boxId = _createMag7();
        vm.prank(admin);
        engine.setComponentRoute(boxId, 0, address(adapter), adapterPath);

        comps[0] = BoxEngine.Component({
            token: address(stocks[0]),
            weightBps: 10_000,
            router: address(router),
            path: _v2Path(address(stocks[0])),
            feed: address(0)
        });
        vm.prank(admin);
        (uint256 noFeedBox,,) = engine.createBox("NoFeed", "NF", comps, 30, 30, 15 ether, "");
        vm.prank(admin);
        vm.expectRevert(BoxEngine.BadRoute.selector);
        engine.setComponentRoute(noFeedBox, 0, address(adapter), adapterPath);
    }

    function testSimulateMintUsesAdapterQuoteForAdapterRoutes() public {
        MockAdapter adapter = new MockAdapter();
        adapter.setRate(address(stocks[0]), 40e18);
        BoxEngine.Component[] memory comps = new BoxEngine.Component[](1);
        address[] memory adapterPath = new address[](2);
        adapterPath[0] = address(0);
        adapterPath[1] = address(stocks[0]);
        comps[0] = BoxEngine.Component({
            token: address(stocks[0]),
            weightBps: 10_000,
            router: address(adapter),
            path: adapterPath,
            feed: address(feeds[0])
        });
        vm.prank(admin);
        (uint256 boxId,,) = engine.createBox("One", "ONE", comps, 30, 30, 15 ether, "");
        vm.prank(user);
        engine.mint{value: 1 ether}(boxId, 0, user);
        adapter.setRate(address(stocks[0]), 20e18);
        uint256 oldQuote = engine.quoteMint(boxId, 1 ether);
        uint256 simulated = engine.simulateMint(boxId, 1 ether);
        assertLt(simulated, oldQuote);
    }

    function _v2Path(address token) internal view returns (address[] memory path) {
        path = new address[](2);
        path[0] = weth;
        path[1] = token;
    }
}

