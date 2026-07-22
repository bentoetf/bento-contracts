// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

interface ISafeProxyFactoryTest {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    function proxyCreationCode() external pure returns (bytes memory);
}

interface ISafeL2Test {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
}

contract DeploySafeForkTest is Test {
    address constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;

    function setUp() public {
        if (keccak256(bytes(vm.envOr("RUN_LIVE_FORK", string("false")))) != keccak256(bytes("true"))) return;
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
    }

    function testDeploySafeProxyFactoryFork() public {
        if (block.chainid != 4663) return;
        address[] memory owners = new address[](3);
        owners[0] = address(0x1001);
        owners[1] = address(0x1002);
        owners[2] = address(0x1003);
        bytes memory initializer = abi.encodeCall(
            ISafeL2Test.setup,
            (owners, uint256(2), address(0), bytes(""), address(0), address(0), uint256(0), payable(address(0)))
        );
        uint256 saltNonce = uint256(keccak256("BENTO_SAFE_FORK_TEST"));
        address predicted = _predictSafe(SAFE_L2_SINGLETON, initializer, saltNonce);
        address deployed =
            ISafeProxyFactoryTest(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_L2_SINGLETON, initializer, saltNonce);
        assertEq(deployed, predicted);
        assertEq(ISafeL2Test(deployed).getThreshold(), 2);
        address[] memory actualOwners = ISafeL2Test(deployed).getOwners();
        assertEq(actualOwners.length, 3);
        console2.log("Predicted Safe", predicted);
        console2.log("Deployed Safe", deployed);
    }

    function _predictSafe(address singleton, bytes memory initializer, uint256 saltNonce)
        internal
        view
        returns (address)
    {
        bytes memory deploymentData = abi.encodePacked(
            ISafeProxyFactoryTest(SAFE_PROXY_FACTORY).proxyCreationCode(), uint256(uint160(singleton))
        );
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), SAFE_PROXY_FACTORY, salt, keccak256(deploymentData))))
            )
        );
    }
}
