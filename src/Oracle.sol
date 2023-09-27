// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {IAggregatorV3} from "./Interfaces/IAggregatorV3.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Errors} from "./Errors.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import "forge-std/Test.sol";

interface IOracle {
    function updatePricefeedConfig(
        address token, 
        IAggregatorV3 priceFeed, 
        uint256 heartBeatDuration, 
        uint256 priceFeedFactor
    ) external;

    function getTokenPrice(address token) external view returns (uint256);
}


contract Oracle is IOracle, Ownable2Step {
    using SafeCast for int256;

    struct PricefeedConfig {
        IAggregatorV3 priceFeed;
        uint256 heartBeatDuration;
        uint256 priceFeedFactor;
    }

    mapping(address => PricefeedConfig) public tokenToConfig;

    function updatePricefeedConfig(
        address token, 
        IAggregatorV3 priceFeed, 
        uint256 heartBeatDuration, 
        uint256 priceFeedFactor
    ) external onlyOwner {
        tokenToConfig[token] = PricefeedConfig(priceFeed, heartBeatDuration, priceFeedFactor);
    }

    function getTokenPrice(address token) external view returns (uint256) {
        PricefeedConfig memory config = tokenToConfig[token];
        (
            /* uint80 roundID */,
            int256 price,
            /* uint256 startedAt */,
            uint256 timestamp,
            /* uint80 answeredInRound */
        ) = config.priceFeed.latestRoundData();

        if (price <= 0) revert Errors.InvalidFeedPrice(address(config.priceFeed), price);
        if (block.timestamp - timestamp > config.heartBeatDuration) {
            revert Errors.PriceFeedNotUpdated(address(config.priceFeed), timestamp, config.heartBeatDuration);
        }

        uint256 adjustedPrice = price.toUint256() * config.priceFeedFactor;

        return adjustedPrice;
    }

}