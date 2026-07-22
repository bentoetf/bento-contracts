// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";

contract RobinhoodV4AdapterForkTest is Test {
    address constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address constant GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address constant AMZN = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address constant META = 0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35;
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    UniswapV4Adapter adapter;

    function setUp() public {
        string memory run = vm.envOr("RUN_LIVE_FORK", string("false"));
        if (keccak256(bytes(run)) != keccak256(bytes("true"))) return;
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        adapter = new UniswapV4Adapter(UNIVERSAL_ROUTER, QUOTER, PERMIT2, USDG, address(this));
        _setUSDG(NVDA, 3000, 60);
        _setUSDG(AAPL, 3000, 60);
        _setUSDG(MSFT, 3000, 60);
        _setUSDG(GOOGL, 3000, 60);
        _setUSDG(AMZN, 3000, 60);
        _setUSDG(META, 3000, 60);
        _setUSDG(TSLA, 3000, 60);
    }

    function testRawNVDAAndAdapterRoundTrip() public {
        if (address(adapter) == address(0)) return;
        uint256 startEth = address(this).balance;
        uint256 nvdaOut = adapter.swapETHToToken{value: 0.1 ether}(NVDA, 1, address(this));
        assertGt(nvdaOut, 0, "NVDA out");
        IERC20(NVDA).approve(address(adapter), nvdaOut);
        uint256 ethBack = adapter.swapTokenToETH(NVDA, nvdaOut, 1, address(this));
        assertGt(ethBack, 0, "ETH back");
        uint256 spent = 0.1 ether - ethBack;
        uint256 bps = spent * 10_000 / 0.1 ether;
        console2.log("NVDA 0.1 ETH out", nvdaOut);
        console2.log("NVDA round-trip ETH back", ethBack);
        console2.log("NVDA round-trip bps", bps);
        assertLt(address(this).balance, startEth);
    }

    function testAdapterRoundTripAllMag7SmallSize() public {
        if (address(adapter) == address(0)) return;
        address[7] memory tokens = [NVDA, AAPL, MSFT, GOOGL, AMZN, META, TSLA];
        string[7] memory symbols = ["NVDA", "AAPL", "MSFT", "GOOGL", "AMZN", "META", "TSLA"];
        for (uint256 i; i < tokens.length; ++i) {
            uint256 amountIn = 0.01 ether;
            uint256 tokenOut = adapter.swapETHToToken{value: amountIn}(tokens[i], 1, address(this));
            assertGt(tokenOut, 0, symbols[i]);
            IERC20(tokens[i]).approve(address(adapter), tokenOut);
            uint256 ethBack = adapter.swapTokenToETH(tokens[i], tokenOut, 1, address(this));
            assertGt(ethBack, 0, symbols[i]);
            console2.log(symbols[i], tokenOut, ethBack, (amountIn - ethBack) * 10_000 / amountIn);
        }
    }

    function _setDirect(address token, uint24 fee, int24 tickSpacing) internal {
        UniswapV4Adapter.PoolKey memory p = UniswapV4Adapter.PoolKey({
            currency0: address(0), currency1: token, fee: fee, tickSpacing: tickSpacing, hooks: address(0)
        });
        adapter.setDirectRoute(token, p);
    }

    function _setUSDG(address token, uint24 stockFee, int24 stockTickSpacing) internal {
        UniswapV4Adapter.PoolKey memory ethUsd = UniswapV4Adapter.PoolKey({
            currency0: address(0), currency1: USDG, fee: 460, tickSpacing: 9, hooks: address(0)
        });
        UniswapV4Adapter.PoolKey memory usdStock = UniswapV4Adapter.PoolKey({
            currency0: token < USDG ? token : USDG,
            currency1: token < USDG ? USDG : token,
            fee: stockFee,
            tickSpacing: stockTickSpacing,
            hooks: address(0)
        });
        adapter.setUSDGRoute(token, ethUsd, usdStock);
    }

    receive() external payable {}
}
