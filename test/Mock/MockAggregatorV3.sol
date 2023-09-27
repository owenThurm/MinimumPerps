// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "../../src/Interfaces/IAggregatorV3.sol";

contract MockAggregatorV3 is IAggregatorV3 {
    uint8 public override decimals;
    string public override description;
    uint256 public override version;
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound;

    constructor(
        uint8 _decimals,
        string memory _description,
        uint256 _version,
        uint80 _roundId,
        int256 _answer,
        uint256 _startedAt,
        uint256 _updatedAt,
        uint80 _answeredInRound
    ) {
        decimals = _decimals;
        description = _description;
        version = _version;
        roundId = 1;
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
        answeredInRound = 2;
    }

    function getRoundData(uint80) external view override returns (uint80, int256, uint256, uint256, uint80) {
        uint256 timeUpdated = block.timestamp - 1 hours;
        return (roundId, answer, startedAt, timeUpdated, answeredInRound);
    }

    function setPrice(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function latestRound() external view override returns (uint256) {
        return uint256(roundId);
    }
}
