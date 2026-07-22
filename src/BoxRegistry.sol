// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Registry mapping box ids to the engine version that created/serves them.
contract BoxRegistry {
    address public immutable owner;
    address public registrar;
    mapping(uint256 => address) public engineOf;

    error NotOwner();
    error NotRegistrar();
    error AlreadyRegistered();
    error RegistrarAlreadySet();

    event RegistrarSet(address indexed registrar);
    event BoxRegistered(uint256 indexed boxId, address indexed engine);

    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Wires the engine registrar once after engine deployment.
    function setRegistrar(address registrar_) external {
        if (msg.sender != owner) revert NotOwner();
        if (registrar != address(0)) revert RegistrarAlreadySet();
        registrar = registrar_;
        emit RegistrarSet(registrar_);
    }

    /// @notice Registers a box id to an engine once. Intended registrar is the active engine version.
    function register(uint256 boxId, address engine) external {
        if (msg.sender != registrar) revert NotRegistrar();
        if (engineOf[boxId] != address(0)) revert AlreadyRegistered();
        engineOf[boxId] = engine;
        emit BoxRegistered(boxId, engine);
    }
}
