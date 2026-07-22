// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    function proxyCreationCode() external pure returns (bytes memory);
}

interface ISafeL2 {
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
}

/// @notice Standalone Safe deploy helper. Not part of Bento protocol deployment.
contract DeploySafe is Script {
    address public constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address public constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;

    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address[] memory owners = new address[](3);
        owners[0] = vm.envAddress("SAFE_OWNER_1");
        owners[1] = vm.envAddress("SAFE_OWNER_2");
        owners[2] = vm.envAddress("SAFE_OWNER_3");
        uint256 saltNonce = vm.envOr("SAFE_SALT_NONCE", uint256(0));
        bytes memory initializer = _initializer(owners);

        address predicted = _predictSafe(SAFE_L2_SINGLETON, initializer, saltNonce);
        console2.log("Predicted Safe", predicted);

        vm.startBroadcast(key);
        address deployed =
            ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_L2_SINGLETON, initializer, saltNonce);
        vm.stopBroadcast();
        console2.log("Deployed Safe", deployed);
    }

    function _initializer(address[] memory owners) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ISafeL2.setup,
            (owners, uint256(2), address(0), bytes(""), address(0), address(0), uint256(0), payable(address(0)))
        );
    }

    function _predictSafe(address singleton, bytes memory initializer, uint256 saltNonce)
        internal
        view
        returns (address)
    {
        bytes memory deploymentData = abi.encodePacked(
            ISafeProxyFactory(SAFE_PROXY_FACTORY).proxyCreationCode(), uint256(uint160(singleton))
        );
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), SAFE_PROXY_FACTORY, salt, keccak256(deploymentData))))
            )
        );
    }
}
