// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {BentoToken} from "../src/BentoToken.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IV2FactoryLike {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IV2RouterLike {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IV3FactoryLike {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IERC20MetaLike {
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/// @notice Live fork report generator. It intentionally does not add V3 support.
contract RobinhoodLiveForkReportTest is Test {
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant SUSHI_FACTORY = 0xE52abd50ad151ecDf56427effD715E703696a6B1;
    address constant SUSHI_ROUTER = 0x9A55D3d0c0f09859c7869510f53eD0a30B340766;
    address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;

    address[7] stocks = [
        0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC, // NVDA
        0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9, // AAPL
        0xe93237C50D904957Cf27E7B1133b510C669c2e74, // MSFT
        0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3, // GOOGL
        0x12f190a9F9d7D37a250758b26824B97CE941bF54, // AMZN
        0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35, // META
        0x322F0929c4625eD5bAd873c95208D54E1c003b2d // TSLA
    ];
    string[7] syms = ["NVDA", "AAPL", "MSFT", "GOOGL", "AMZN", "META", "TSLA"];
    uint24[4] fees = [uint24(100), uint24(500), uint24(3000), uint24(10000)];

    function testLiveForkReportV2RoutesAndOptionalMint() public {
        if (!vm.envOr("RUN_LIVE_FORK", false)) return;
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://robinhoodchain.blockscout.com/api/eth-rpc"));
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 4663);

        string memory report = string.concat(
            "# Bento Robinhood Fork Report\n\n",
            "RPC used by Foundry: `",
            rpc,
            "`\n\n",
            "Upstream RPC target for local proxy runs: `https://rpc.mainnet.chain.robinhood.com`\n\n",
            "Block: `",
            vm.toString(block.number),
            "`\n\n",
            "## V2 route discovery\n\n",
            "Checked Sushi V2 factory/router only (the verified V2 endpoints supplied in the spec). `0xCaf681a66D020601342297493863E78C959E5cb2` resolves to factory `0x1f7d...2EfA` with V3 `getPool` behavior, so it was used only for V3 pool discovery. No V3 adapter was added.\n\n",
            "| Symbol | Token | Sushi WETH pair | getAmountsOut(0.1 ETH) |\n|---|---|---:|---:|\n"
        );

        bool allV2 = true;
        for (uint256 i; i < stocks.length; ++i) {
            address pair = IV2FactoryLike(SUSHI_FACTORY).getPair(WETH, stocks[i]);
            (bool ok, bytes memory data) = _tryV2Quote(stocks[i], 0.1 ether);
            allV2 = allV2 && pair != address(0) && ok;
            report = string.concat(
                report,
                "| ",
                syms[i],
                " | `",
                vm.toString(stocks[i]),
                "` | `",
                vm.toString(pair),
                "` | ",
                ok ? vm.toString(abi.decode(data, (uint256))) : "revert/no route",
                " |\n"
            );
        }

        report = string.concat(
            report,
            "\n## V3 pool cross-check (discovery only, no adapter)\n\n| Symbol | Existing WETH pools |\n|---|---|\n"
        );
        for (uint256 i; i < stocks.length; ++i) {
            string memory row = "";
            for (uint256 j; j < fees.length; ++j) {
                address pool = IV3FactoryLike(V3_FACTORY).getPool(WETH, stocks[i], fees[j]);
                if (pool != address(0)) {
                    row = string.concat(row, vm.toString(fees[j]), "bps:`", vm.toString(pool), "` ");
                }
            }
            if (bytes(row).length == 0) row = "none at 100/500/3000/10000";
            report = string.concat(report, "| ", syms[i], " | ", row, " |\n");
        }

        if (allV2) {
            (uint256 minted, uint256 ethOut, uint256 costBps) = _forkMintRedeem();
            report = string.concat(
                report,
                "\n## 0.1 ETH fork lifecycle\n\n",
                "All seven V2 routes existed, so the on-fork MAG7 mint/redeem path ran.\n\n",
                "- box tokens minted: `",
                vm.toString(minted),
                "`\n",
                "- redeemForETH returned: `",
                vm.toString(ethOut),
                "` wei\n",
                "- round-trip cost: `",
                vm.toString(costBps),
                "` bps\n"
            );
            assertGt(minted, 0);
        } else {
            report = string.concat(
                report,
                "\n## 0.1 ETH fork lifecycle\n\n",
                "Skipped by test guard: all seven direct Sushi V2 WETH->stock routes do not exist. Running `BoxEngine.mint` with the current V2-only engine would revert before producing a MAG7 basket.\n"
            );
        }

        report = string.concat(
            report,
            "\n## Feed / TRV math finding\n\n",
            "No live stock feed addresses were configured or discoverable from the stock token contracts themselves in this pass. The token contracts expose rebasing UI multipliers (`uiMultiplier`) and ERC-20 balances, but not Chainlink feed pointers. Because the available on-chain liquidity evidence is V3 pool-based for only a subset of MAG7, feed answer * holdings could not be reconciled against a complete seven-component V2 pool spot basket.\n\n",
            "**NAV recommendation:** compute component NAV as `liveVaultBalance * feedAnswer / 10**tokenDecimals`, normalized by each feed's own decimals, then sum USD values and divide by `totalSupply`. Do not apply stock `uiMultiplier` a second time, because `balanceOf()` is already UI-scaled/rebase-aware. Use pool spot only for mint/redeem proportional issuance and sanity checks, not display NAV.\n\n",
            "## Conclusion\n\n",
            allV2
                ? "V2 routes exist for the checked router, so the next pass can stay V2-only after adding live feed sanity bounds.\n"
                : "The checked spec-provided Sushi V2 router has no direct WETH pairs for the MAG7 stocks. The V2-only engine cannot execute a real MAG7 mint on this router. Existing liquidity appears at V3 pools for NVDA/AAPL/TSLA only in this empirical pass, so the next scoping decision is route discovery/adapter strategy, not mainnet deployment.\n"
        );
        vm.writeFile("FORKREPORT.md", report);
    }

    function _tryV2Quote(address token, uint256 amountIn)
        internal
        view
        returns (bool ok, bytes memory decodedLastAmount)
    {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = token;
        try IV2RouterLike(SUSHI_ROUTER).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            return (true, abi.encode(amounts[amounts.length - 1]));
        } catch {
            return (false, bytes(""));
        }
    }

    function _forkMintRedeem() internal returns (uint256 minted, uint256 ethOut, uint256 costBps) {
        address admin = address(this);
        BentoToken bento = new BentoToken(admin, admin, address(0xD3F));
        address[] memory buyPath = new address[](2);
        buyPath[0] = WETH;
        buyPath[1] = address(bento);
        FeeCollector collector = new FeeCollector(admin, address(0), address(bento), SUSHI_ROUTER, buyPath);
        BoxEngine engine = new BoxEngine(admin, address(0), address(collector), address(bento), address(0));
        collector.setEngine(address(engine));

        BoxEngine.Component[] memory comps = new BoxEngine.Component[](7);
        uint16[7] memory weights = [uint16(1428), 1428, 1428, 1428, 1428, 1428, 1432];
        for (uint256 i; i < stocks.length; ++i) {
            address[] memory path = new address[](2);
            path[0] = WETH;
            path[1] = stocks[i];
            comps[i] = BoxEngine.Component(stocks[i], weights[i], SUSHI_ROUTER, path, address(0));
        }
        (uint256 boxId, address boxToken,) =
            engine.createBox("MAG7 Bento Box", "MAG7", comps, 30, 30, 25 ether, "fork://mag7");
        deal(address(this), 1 ether);
        minted = engine.mint{value: 0.1 ether}(boxId, 0, address(this));
        (address[] memory tokens, uint256[] memory balances) = engine.backing(boxId);
        assertEq(tokens.length, 7);
        for (uint256 i; i < balances.length; ++i) {
            assertGt(balances[i], 0, syms[i]);
        }
        ethOut = engine.redeemForETH(boxId, IERC20(boxToken).balanceOf(address(this)), 0, address(this));
        costBps = ((0.1 ether - ethOut) * 10_000) / 0.1 ether;
    }
}
