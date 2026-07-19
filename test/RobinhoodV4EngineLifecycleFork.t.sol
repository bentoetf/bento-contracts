// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {BoxRegistry} from "../src/BoxRegistry.sol";
import {BentoToken} from "../src/BentoToken.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {IBoxToken} from "../src/interfaces.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

contract RobinhoodV4EngineLifecycleForkTest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant SUSHI_ROUTER = 0x9A55D3d0c0f09859c7869510f53eD0a30B340766;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    address[7] STOCKS = [
        address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC),
        address(0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9),
        address(0xe93237C50D904957Cf27E7B1133b510C669c2e74),
        address(0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3),
        address(0x12f190a9F9d7D37a250758b26824B97CE941bF54),
        address(0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35),
        address(0x322F0929c4625eD5bAd873c95208D54E1c003b2d)
    ];
    address[7] FEEDS = [
        address(0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15),
        address(0x6B22A786bAa607d76728168703a39Ea9C99f2cD0),
        address(0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E),
        address(0xF6f373a037c30F0e5010d854385cA89185AE638b),
        address(0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C),
        address(0x7C38C00C30BEe9378381E7B6135d7283356D71b1),
        address(0x4A1166a659A55625345e9515b32adECea5547C38)
    ];

    function setUp() public {
        if (keccak256(bytes(vm.envOr("RUN_LIVE_FORK", string("false")))) != keccak256(bytes("true"))) return;
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
    }

    function testFullForkLifecycleMAG7V4Adapter() public {
        if (block.chainid != 4663) return;
        (BoxEngine engine, UniswapV4Adapter adapter,) = _deployStack();
        _setRoutes(adapter);
        (uint256 boxId, address boxToken, address vault) = _createMag7(engine, adapter);
        assertEq(boxToken.code.length > 0, true);
        assertEq(vault.code.length > 0, true);

        vm.expectRevert(BoxEngine.PerTxMintCapExceeded.selector);
        engine.mint{value: 3 ether}(boxId, 0, address(this));

        uint256 ethStart = address(this).balance;
        uint256 first = engine.mint{value: 0.5 ether}(boxId, 0, address(this));
        assertGt(first, 0);
        (address[] memory tokens, uint256[] memory balances) = engine.backing(boxId);
        assertEq(tokens.length, 7);
        for (uint256 i; i < balances.length; ++i) {
            assertGt(balances[i], 0);
        }
        uint256 navUsd = engine.navUsdPerBox(boxId);
        assertApproxEqRel(navUsd, 100e18, 0.04e18);

        uint256 second = engine.mint{value: 0.5 ether}(boxId, 0, address(this));
        assertApproxEqRel(second, first, 0.04e18);

        IBoxToken(boxToken).approve(address(engine), type(uint256).max);
        uint256 half = IBoxToken(boxToken).balanceOf(address(this)) / 2;
        engine.redeemForStocks(boxId, half, address(this));
        assertGt(IERC20(STOCKS[0]).balanceOf(address(this)), 0);

        uint256 remaining = IBoxToken(boxToken).balanceOf(address(this));
        uint256 ethOut = engine.redeemForETH(boxId, remaining, 0, address(this));
        assertGt(ethOut, 0);
        uint256 spent = ethStart - address(this).balance;
        console2.log("MAG7 full lifecycle first box out", first);
        console2.log("MAG7 full lifecycle second box out", second);
        console2.log("MAG7 NAV USD per box", navUsd);
        console2.log("MAG7 redeemForETH out", ethOut);
        console2.log("MAG7 lifecycle net bps including stock half held", spent * 10_000 / 1 ether);
        console2.log("buybackAndBurn skipped: no BENTO pool exists yet");
    }

    function testImmediateMintRedeemForETHAllInBps() public {
        if (block.chainid != 4663) return;
        _roundTripBps(0.1 ether);
        _roundTripBps(0.5 ether);
        _roundTripBps(2 ether);
    }

    function _deployStack() internal returns (BoxEngine engine, UniswapV4Adapter adapter, BoxRegistry registry) {
        address admin = address(this);
        BentoToken bento = new BentoToken(admin, admin, address(0xD3F));
        address[] memory buybackPath = new address[](2);
        buybackPath[0] = WETH;
        buybackPath[1] = address(bento);
        FeeCollector collector = new FeeCollector(admin, address(0), address(bento), SUSHI_ROUTER, buybackPath);
        registry = new BoxRegistry(admin);
        adapter = new UniswapV4Adapter(UNIVERSAL_ROUTER, QUOTER, PERMIT2, USDG, admin);
        engine = new BoxEngine(admin, address(registry), address(collector), address(bento), ETH_USD_FEED);
        // Live stock feeds can sit untouched across equity-market weekends; keep production default at 24h, but widen the fork acceptance run.
        engine.setMaxFeedAge(72 hours);
        registry.setRegistrar(address(engine));
        collector.setEngine(address(engine));
    }

    function _createMag7(BoxEngine engine, UniswapV4Adapter adapter)
        internal
        returns (uint256 boxId, address boxToken, address vault)
    {
        BoxEngine.Component[] memory comps = new BoxEngine.Component[](7);
        uint16[7] memory weights = [uint16(1428), 1428, 1428, 1428, 1428, 1428, 1432];
        for (uint256 i; i < 7; ++i) {
            address[] memory path = new address[](2);
            path[0] = address(0);
            path[1] = STOCKS[i];
            comps[i] = BoxEngine.Component({
                token: STOCKS[i], weightBps: weights[i], router: address(adapter), path: path, feed: FEEDS[i]
            });
        }
        (boxId, boxToken, vault) = engine.createBox("MAG7 Bento Box", "MAG7", comps, 30, 30, 15 ether, "");
        engine.setPerTxMintCap(boxId, 2 ether);
    }

    function _roundTripBps(uint256 amountIn) internal {
        (BoxEngine engine, UniswapV4Adapter adapter,) = _deployStack();
        _setRoutes(adapter);
        (uint256 boxId, address boxToken,) = _createMag7(engine, adapter);
        uint256 beforeEth = address(this).balance;
        uint256 boxOut = engine.mint{value: amountIn}(boxId, 0, address(this));
        IBoxToken(boxToken).approve(address(engine), boxOut);
        uint256 ethOut = engine.redeemForETH(boxId, boxOut, 0, address(this));
        uint256 bps = (amountIn - ethOut) * 10_000 / amountIn;
        assertGt(ethOut, 0);
        assertEq(address(this).balance, beforeEth - amountIn + ethOut);
        console2.log("MAG7 immediate round-trip amount", amountIn);
        console2.log("MAG7 immediate round-trip ethOut", ethOut);
        console2.log("MAG7 immediate round-trip all-in bps", bps);
    }

    function _setRoutes(UniswapV4Adapter adapter) internal {
        for (uint256 i; i < 7; ++i) {
            adapter.setUSDGRoute(STOCKS[i], _ethUsdPool(), _usdStockPool(STOCKS[i]));
        }
    }

    function _ethUsdPool() internal pure returns (UniswapV4Adapter.PoolKey memory p) {
        p = UniswapV4Adapter.PoolKey({
            currency0: address(0), currency1: USDG, fee: 460, tickSpacing: 9, hooks: address(0)
        });
    }

    function _usdStockPool(address token) internal pure returns (UniswapV4Adapter.PoolKey memory p) {
        p = UniswapV4Adapter.PoolKey({
            currency0: token < USDG ? token : USDG,
            currency1: token < USDG ? USDG : token,
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
    }

    receive() external payable {}
}
