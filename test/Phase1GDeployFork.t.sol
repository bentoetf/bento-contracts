// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {BoxRegistry} from "../src/BoxRegistry.sol";
import {BentoToken} from "../src/BentoToken.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {IBoxToken, ISwapAdapterLike} from "../src/interfaces.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

contract Phase1GDeployForkTest is Test {
    uint256 constant BPS = 10_000;
    uint256 constant MAX_ROUND_TRIP_BPS = 200;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant SUSHI_ROUTER = 0x9A55D3d0c0f09859c7869510f53eD0a30B340766;
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;

    address safe = address(0x515AFE);
    address devWallet = address(0xD3F);
    address lpSeeder = address(0x1A11CEED);
    BentoToken bento;
    FeeCollector collector;
    BoxRegistry registry;
    UniswapV4Adapter adapter;
    BoxEngine engine;
    TimelockController timelock;

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
        vm.deal(address(this), 10 ether);
    }

    function testPhase1GDeployVerifyAndSmoke() public {
        if (block.chainid != 4663) return;
        _deployBase();
        _verifyBase();
        _timelockExecute(address(collector), abi.encodeCall(FeeCollector.setEngine, (address(engine))));
        _timelockExecute(address(engine), abi.encodeCall(BoxEngine.setMaxFeedAge, (14 days)));
        _timelockExecute(address(bento), abi.encodeCall(BentoToken.setTaxExempt, (address(engine), true)));
        _timelockExecute(address(bento), abi.encodeCall(BentoToken.setTaxExempt, (address(collector), true)));
        _timelockExecute(address(bento), abi.encodeCall(BentoToken.setTaxExempt, (collector.DEAD(), true)));
        _timelockExecute(address(bento), abi.encodeCall(BentoToken.setTaxExempt, (lpSeeder, true)));
        _timelockExecute(
            address(engine),
            abi.encodeCall(
                BoxEngine.createBox, ("MAG7 Bento Box", "MAG7", _mag7Components(), 30, 30, uint128(15 ether), "")
            )
        );
        _timelockExecute(address(engine), abi.encodeCall(BoxEngine.setPerTxMintCap, (uint256(1), uint128(2 ether))));

        (address boxToken, address vault, uint16 mintFee, uint16 redeemFee, uint128 tvlCap, bool paused, bool exists,) =
            engine.boxes(1);
        assertTrue(exists);
        assertFalse(paused);
        assertEq(mintFee, 30);
        assertEq(redeemFee, 30);
        assertEq(tvlCap, 15 ether);
        assertEq(engine.perTxMintCapWei(1), 2 ether);
        assertEq(registry.engineOf(1), address(engine));
        assertTrue(bento.taxExempt(address(engine)));
        assertTrue(bento.taxExempt(address(collector)));
        assertTrue(bento.taxExempt(collector.DEAD()));
        assertTrue(bento.taxExempt(lpSeeder));

        BoxEngine.Component[] memory comps = engine.components(1);
        for (uint256 i; i < comps.length; ++i) {
            assertEq(comps[i].token, STOCKS[i]);
            assertEq(comps[i].feed, FEEDS[i]);
            assertEq(comps[i].router, address(adapter));
            assertEq(comps[i].path[0], address(0));
            assertEq(comps[i].path[1], STOCKS[i]);
        }

        uint256 smokeAmount = 0.01 ether;
        uint256[] memory mintMins = _mintMins(smokeAmount);
        uint256 boxOut = engine.mint{value: smokeAmount}(1, 0, address(this), mintMins);
        IBoxToken(boxToken).approve(address(engine), boxOut);
        uint256[] memory redeemMins = _redeemMins(boxOut);
        uint256 ethOut = engine.redeemForETH(1, boxOut, 0, redeemMins, address(this));
        uint256 bps = (smokeAmount - ethOut) * BPS / smokeAmount;
        assertLe(bps, MAX_ROUND_TRIP_BPS);
        console2.log("Phase1G timelock", address(timelock));
        console2.log("Phase1G bento", address(bento));
        console2.log("Phase1G feeCollector", address(collector));
        console2.log("Phase1G registry", address(registry));
        console2.log("Phase1G adapter", address(adapter));
        console2.log("Phase1G engine", address(engine));
        console2.log("Phase1G MAG7 boxToken", boxToken);
        console2.log("Phase1G MAG7 vault", vault);
        console2.log("Phase1G smoke ethOut", ethOut);
        console2.log("Phase1G smoke bps", bps);
    }

    function _deployBase() internal {
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;
        timelock = new TimelockController(24 hours, proposers, executors, safe);
        bento = new BentoToken(address(this), address(timelock), devWallet);
        address[] memory buybackPath = new address[](2);
        buybackPath[0] = WETH;
        buybackPath[1] = address(bento);
        collector = new FeeCollector(address(timelock), address(0), address(bento), SUSHI_ROUTER, buybackPath);
        registry = new BoxRegistry(address(this));
        adapter = new UniswapV4Adapter(UNIVERSAL_ROUTER, QUOTER, PERMIT2, USDG, address(this));
        for (uint256 i; i < 7; ++i) {
            adapter.setUSDGRoute(STOCKS[i], _ethUsdPool(), _usdStockPool(STOCKS[i]));
        }
        adapter.transferOwnership(address(timelock));
        engine = new BoxEngine(address(timelock), address(registry), address(collector), address(bento), ETH_USD_FEED);
        registry.setRegistrar(address(engine));
    }

    function _verifyBase() internal view {
        assertEq(bento.admin(), address(timelock));
        assertEq(bento.devWallet(), devWallet);
        assertEq(bento.taxBps(), 300);
        assertEq(collector.admin(), address(timelock));
        assertEq(collector.bento(), address(bento));
        assertEq(engine.admin(), address(timelock));
        assertEq(engine.registry(), address(registry));
        assertEq(engine.feeCollector(), address(collector));
        assertEq(engine.bento(), address(bento));
        assertEq(engine.ethUsdFeed(), ETH_USD_FEED);
        assertEq(registry.registrar(), address(engine));
        assertEq(Ownable(address(adapter)).owner(), address(timelock));
    }

    function _timelockExecute(address target, bytes memory data) internal {
        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256(data);
        vm.prank(safe);
        timelock.schedule(target, 0, data, predecessor, salt, 24 hours);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(safe);
        timelock.execute(target, 0, data, predecessor, salt);
    }

    function _mintMins(uint256 ethIn) internal returns (uint256[] memory mins) {
        BoxEngine.Component[] memory comps = engine.components(1);
        mins = new uint256[](comps.length);
        uint256 net = ethIn - (ethIn * 30 / BPS);
        uint256 remaining = net;
        for (uint256 i; i < comps.length; ++i) {
            uint256 part = i == comps.length - 1 ? remaining : (net * comps[i].weightBps) / BPS;
            remaining -= part;
            mins[i] = ISwapAdapterLike(comps[i].router).quoteETHToToken(comps[i].token, part) * 9800 / BPS;
        }
    }

    function _redeemMins(uint256 boxIn) internal returns (uint256[] memory mins) {
        BoxEngine.Component[] memory comps = engine.components(1);
        mins = new uint256[](comps.length);
        (address boxToken, address vault,,,,,,) = engine.boxes(1);
        uint256 supply = IERC20(boxToken).totalSupply();
        for (uint256 i; i < comps.length; ++i) {
            uint256 amount = IERC20(comps[i].token).balanceOf(vault) * boxIn / supply;
            mins[i] = ISwapAdapterLike(comps[i].router).quoteTokenToETH(comps[i].token, amount) * 9800 / BPS;
        }
    }

    function _mag7Components() internal view returns (BoxEngine.Component[] memory comps) {
        comps = new BoxEngine.Component[](7);
        uint16[7] memory weights = [uint16(1428), 1428, 1428, 1428, 1428, 1428, 1432];
        for (uint256 i; i < 7; ++i) {
            address[] memory path = new address[](2);
            path[0] = address(0);
            path[1] = STOCKS[i];
            comps[i] = BoxEngine.Component({
                token: STOCKS[i], weightBps: weights[i], router: address(adapter), path: path, feed: FEEDS[i]
            });
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
