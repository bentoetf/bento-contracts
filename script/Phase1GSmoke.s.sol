// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BoxEngine} from "../src/BoxEngine.sol";
import {IBoxToken, ISwapAdapterLike} from "../src/interfaces.sol";

/// @notice Post-deploy smoke: 0.01 ETH mint and immediate redeemForETH with per-component mins.
/// @dev Requires deployed stack with MAG7 boxId=1 unless BOX_ID is overridden.
contract Phase1GSmoke is Script {
    uint256 constant BPS = 10_000;
    uint256 constant SMOKE_AMOUNT = 0.01 ether;
    uint256 constant SLIPPAGE_BPS = 200; // 2% per-leg tolerance for smoke.
    uint256 constant MAX_ROUND_TRIP_BPS = 200;

    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(key);
        BoxEngine engine = BoxEngine(payable(vm.envAddress("BOX_ENGINE_ADDRESS")));
        uint256 boxId = vm.envOr("BOX_ID", uint256(1));

        (address boxToken,,,,,,,) = engine.boxes(boxId);
        require(boxToken != address(0), "BOX_NOT_CREATED");

        uint256[] memory mintMins = _mintMins(engine, boxId, SMOKE_AMOUNT);
        uint256 beforeEth = sender.balance;

        vm.startBroadcast(key);
        uint256 boxOut = engine.mint{value: SMOKE_AMOUNT}(boxId, 0, sender, mintMins);
        IBoxToken(boxToken).approve(address(engine), boxOut);
        vm.stopBroadcast();

        uint256[] memory redeemMins = _redeemMins(engine, boxId, boxOut);

        vm.startBroadcast(key);
        uint256 ethOut = engine.redeemForETH(boxId, boxOut, 0, redeemMins, sender);
        vm.stopBroadcast();

        uint256 bps = (SMOKE_AMOUNT - ethOut) * BPS / SMOKE_AMOUNT;
        require(ethOut > 0, "NO_ETH_OUT");
        require(bps <= MAX_ROUND_TRIP_BPS, "ROUND_TRIP_TOO_HIGH");

        console2.log("smoke sender", sender);
        console2.log("smoke boxToken", boxToken);
        console2.log("smoke eth before", beforeEth);
        console2.log("smoke box out", boxOut);
        console2.log("smoke eth out", ethOut);
        console2.log("smoke round-trip bps", bps);
    }

    function _mintMins(BoxEngine engine, uint256 boxId, uint256 ethIn) internal returns (uint256[] memory mins) {
        BoxEngine.Component[] memory comps = engine.components(boxId);
        mins = new uint256[](comps.length);
        (,, uint16 mintFeeBps,,,,,) = engine.boxes(boxId);
        uint256 net = ethIn - (ethIn * mintFeeBps / BPS);
        uint256 remaining = net;
        for (uint256 i; i < comps.length; ++i) {
            uint256 part = i == comps.length - 1 ? remaining : (net * comps[i].weightBps) / BPS;
            remaining -= part;
            uint256 quoted = ISwapAdapterLike(comps[i].router).quoteETHToToken(comps[i].token, part);
            mins[i] = quoted * (BPS - SLIPPAGE_BPS) / BPS;
        }
    }

    function _redeemMins(BoxEngine engine, uint256 boxId, uint256 boxIn) internal returns (uint256[] memory mins) {
        BoxEngine.Component[] memory comps = engine.components(boxId);
        mins = new uint256[](comps.length);
        (address boxToken, address vault,,,,,,) = engine.boxes(boxId);
        uint256 supply = IERC20(boxToken).totalSupply();
        for (uint256 i; i < comps.length; ++i) {
            uint256 amount = IERC20(comps[i].token).balanceOf(vault) * boxIn / supply;
            uint256 quoted = ISwapAdapterLike(comps[i].router).quoteTokenToETH(comps[i].token, amount);
            mins[i] = quoted * (BPS - SLIPPAGE_BPS) / BPS;
        }
    }
}
