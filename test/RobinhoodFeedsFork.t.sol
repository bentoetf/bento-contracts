// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IScaledStockRead {
    function decimals() external view returns (uint8);
    function uiMultiplier() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalSupplyUI() external view returns (uint256);
}

contract RobinhoodFeedsForkTest is Test {
    address[8] feeds = [
        0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15, // NVDA
        0x6B22A786bAa607d76728168703a39Ea9C99f2cD0, // AAPL
        0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E, // MSFT
        0xF6f373a037c30F0e5010d854385cA89185AE638b, // GOOGL
        0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C, // AMZN
        0x7C38C00C30BEe9378381E7B6135d7283356D71b1, // META
        0x4A1166a659A55625345e9515b32adECea5547C38, // TSLA
        0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9 // ETH/USD
    ];
    address[7] stocks = [
        0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC,
        0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9,
        0xe93237C50D904957Cf27E7B1133b510C669c2e74,
        0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3,
        0x12f190a9F9d7D37a250758b26824B97CE941bF54,
        0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35,
        0x322F0929c4625eD5bAd873c95208D54E1c003b2d
    ];
    string[8] symbols = ["NVDA", "AAPL", "MSFT", "GOOGL", "AMZN", "META", "TSLA", "ETH/USD"];

    function setUp() public {
        string memory run = vm.envOr("RUN_LIVE_FORK", string("false"));
        if (keccak256(bytes(run)) != keccak256(bytes("true"))) return;
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
    }

    function testReadFeedsAndScaledSupply() public view {
        if (block.chainid != 4663) return;
        for (uint256 i; i < feeds.length; ++i) {
            uint8 d = IAggregatorV3(feeds[i]).decimals();
            (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feeds[i]).latestRoundData();
            assertGt(answer, 0, symbols[i]);
            console2.log(symbols[i]);
            console2.log("feedDecimals", d);
            console2.log("answer", uint256(answer));
            console2.log("updatedAt", updatedAt);
        }
        for (uint256 i; i < stocks.length; ++i) {
            uint256 mult = IScaledStockRead(stocks[i]).uiMultiplier();
            uint256 rawSupply = IScaledStockRead(stocks[i]).totalSupply();
            uint256 uiSupply = IScaledStockRead(stocks[i]).totalSupplyUI();
            assertEq(uiSupply, rawSupply * mult / 1e18, symbols[i]);
            console2.log(symbols[i]);
            console2.log("stockDecimals", IScaledStockRead(stocks[i]).decimals());
            console2.log("uiMultiplier", mult);
        }
    }
}
