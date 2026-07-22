// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UniswapV4Adapter} from "../src/adapters/UniswapV4Adapter.sol";
import {BentoToken} from "../src/BentoToken.sol";

contract DeployShapeTest is Test {
    address constant UNIVERSAL_ROUTER = address(0x8876789976dEcBfCbBbe364623C63652db8C0904);
    address constant QUOTER = address(0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94);
    address constant PERMIT2 = address(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant USDG = address(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    address constant NVDA = address(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);

    function testAdapterOwnerIsTimelockAfterDeployScriptLogic() public {
        address safe = address(0x515AFE);
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;
        TimelockController timelock = new TimelockController(24 hours, proposers, executors, safe);
        UniswapV4Adapter adapter = new UniswapV4Adapter(UNIVERSAL_ROUTER, QUOTER, PERMIT2, USDG, address(this));
        UniswapV4Adapter.PoolKey memory ethUsd = UniswapV4Adapter.PoolKey({
            currency0: address(0), currency1: USDG, fee: 460, tickSpacing: 9, hooks: address(0)
        });
        UniswapV4Adapter.PoolKey memory usdNvda = UniswapV4Adapter.PoolKey({
            currency0: USDG < NVDA ? USDG : NVDA,
            currency1: USDG < NVDA ? NVDA : USDG,
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        adapter.setUSDGRoute(NVDA, ethUsd, usdNvda);
        adapter.transferOwnership(address(timelock));
        assertEq(adapter.owner(), address(timelock));
    }

    function testBentoAdminIsTimelockAndTaxDefaultsAfterDeployScriptLogic() public {
        address safe = address(0x515AFE);
        address deployer = address(this);
        address devWallet = address(0xD3F);
        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = safe;
        TimelockController timelock = new TimelockController(24 hours, proposers, executors, safe);
        BentoToken bento = new BentoToken(deployer, address(timelock), devWallet);

        assertEq(bento.admin(), address(timelock));
        assertEq(bento.devWallet(), devWallet);
        assertEq(bento.taxBps(), 300);
        assertEq(bento.MAX_TAX_BPS(), 300);
        assertEq(bento.balanceOf(deployer), bento.INITIAL_SUPPLY());
        assertTrue(bento.taxExempt(deployer));
        assertTrue(bento.taxExempt(address(timelock)));
        assertTrue(bento.taxExempt(devWallet));
    }
}
