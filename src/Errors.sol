// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.13;

library Errors {
    error TraderPnlExceedsDeposits();
    error InvalidFeedPrice(address priceFeed, int256 price);
    error PriceFeedNotUpdated(address priceFeed, uint256 lastTimestamp, uint256 heartbeat);
    error EmptyPosition(uint256 sizeInUsd, uint256 sizeInTokens, uint256 collateralAmount);
    error MaxUtilizationBreached(uint256 maxUtilizableDeposits, uint256 totalReserved);
}