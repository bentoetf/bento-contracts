// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBoxEngineNav {
    function navUsdPerBox(uint256 boxId) external view returns (uint256);
    function boxes(uint256 boxId)
        external
        view
        returns (
            address boxToken,
            address vault,
            uint16 mintFeeBps,
            uint16 redeemFeeBps,
            uint128 tvlCapWei,
            bool mintPaused,
            bool exists,
            string memory metadataURI
        );
}

/// @notice Chainlink AggregatorV3-compatible price feed for a Bento box token.
///         Reports the box NAV in USD with 8 decimals, computed live from the
///         engine's component Chainlink feeds and vault balances. Stateless,
///         immutable, no admin. Intended for Morpho market creation and any
///         integration that expects an AggregatorV3Interface.
/// @dev    Freshness: the underlying component feeds enforce their own
///         heartbeat via the engine's maxFeedAge; if a component feed is stale
///         the engine call reverts and so does this oracle, which is the safe
///         failure mode for a lending market (no price -> no new borrows or
///         liquidations at a bogus price). updatedAt is reported as
///         block.timestamp because the value is recomputed live per call.
contract BoxNavOracle {
    IBoxEngineNav public immutable engine;
    uint256 public immutable boxId;
    uint8 public constant decimals = 8;

    error BoxMissing();
    error ZeroNav();

    constructor(address engine_, uint256 boxId_) {
        engine = IBoxEngineNav(engine_);
        boxId = boxId_;
        (,,,,,, bool exists,) = IBoxEngineNav(engine_).boxes(boxId_);
        if (!exists) revert BoxMissing();
    }

    function description() external view returns (string memory) {
        return string.concat("Bento box NAV / USD (boxId ", _toString(boxId), ")");
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    /// @notice NAV in USD with 8 decimals (AggregatorV3 convention).
    function latestAnswer() public view returns (int256) {
        uint256 nav1e18 = engine.navUsdPerBox(boxId);
        if (nav1e18 == 0) revert ZeroNav();
        return int256(nav1e18 / 1e10);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        answer = latestAnswer();
        roundId = 1;
        answeredInRound = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function getRoundData(uint80)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        answer = latestAnswer();
        roundId = 1;
        answeredInRound = 1;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function _toString(uint256 value) internal pure returns (string memory str) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + (value % 10)));
            value /= 10;
        }
        str = string(buffer);
    }
}
