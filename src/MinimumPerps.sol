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

import "forge-std/Test.sol";


contract MinimumPerps is ERC4626 {
    using SafeCast for int256;
    using SafeERC20 for IERC20;

    struct Position {
        uint256 sizeInUsd;
        uint256 sizeInTokens;
        uint256 collateralAmount;
    }

    uint256 public constant PRECISION = 1e30;

    IAggregatorV3 immutable public indexPriceFeed;
    uint256 public indexFeedHeartbeatDuration;
    uint256 public indexFeedFactor;

    IAggregatorV3 immutable public collateralPriceFeed;
    uint256 public collateralFeedHeartbeatDuration;
    uint256 public collateralFeedFactor;

    uint256 public totalCollateral;
    uint256 public totalDeposits;
    
    uint256 public openInterestLong;
    uint256 public openInterestShort;
    uint256 public openInterestTokensLong;
    uint256 public openInterestTokensShort;

    mapping(address => Position) public longPositions;
    mapping(address => Position) public shortPositions;

    // The maximum aggregate OI that can be open as a percentage of the deposits
    uint256 public maxUtilizationRatio = 5e29; // 50%

    constructor(
        string memory _name, 
        string memory _symbol, 
        IERC20 _collateralToken, 
        IAggregatorV3 _indexPriceFeed, 
        uint256 _indexFeedHeartbeatDuration,
        uint256 _indexFeedFactor,
        IAggregatorV3 _collateralPriceFeed, 
        uint256 _collateralFeedHeartbeatDuration,
        uint256 _collateralFeedFactor
    ) ERC20(_name, _symbol) ERC4626(_collateralToken) {
        indexPriceFeed = _indexPriceFeed;
        indexFeedHeartbeatDuration = _indexFeedHeartbeatDuration;
        indexFeedFactor = _indexFeedFactor;
        collateralPriceFeed = _collateralPriceFeed;
        collateralFeedHeartbeatDuration = _collateralFeedHeartbeatDuration;
        collateralFeedFactor = _collateralFeedFactor;
    }

    function getPosition(bool isLong, address user) external returns (Position memory) {
        return isLong ? longPositions[user] : shortPositions[user];
    }

    /**
     * @dev Return the net PnL of traders at the given indexPrice.
     * @param isLong        Direction of traders to compute the PnL of.
     * @param indexPrice    Price of the indexToken.
     * @notice 
     *  OI: cost of position
     *  OI in tokens: size of position
     */
    function getNetPnl(bool isLong, uint256 indexPrice) public view returns (int256 pnl) {
        if (isLong) {
            pnl = int256(openInterestTokensLong * indexPrice) - int256(openInterestLong);
        } else {
            pnl = int256(openInterestShort) - int256(openInterestTokensShort * indexPrice);
        }
    }

    /**
     * @dev Return the net balance of the market for depositors.
     * E.g. total deposited value - trader PnL.
     */
    function totalAssets() public view override returns (uint256) {
        uint256 _totalDeposits = totalDeposits;
        uint256 indexPrice = getIndexPrice();

        int256 traderPnlLong = getNetPnl(true, indexPrice);
        int256 traderPnlShort = getNetPnl(false, indexPrice);

        int256 netTraderPnl = traderPnlLong + traderPnlShort;

        if (netTraderPnl > 0) {
            if (netTraderPnl.toUint256() > _totalDeposits) revert Errors.TraderPnlExceedsDeposits();
            return _totalDeposits - netTraderPnl.toUint256();
        } else return _totalDeposits + (-netTraderPnl).toUint256();
    }


    function increasePosition(bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), collateralDelta);

        mapping(address => Position) storage positions = isLong ? longPositions : shortPositions;

        Position memory position = positions[msg.sender];

        uint256 indexTokenPrice = getIndexPrice();
        uint256 indexTokenDelta = isLong ? sizeDeltaUsd / indexTokenPrice : Math.ceilDiv(sizeDeltaUsd, indexTokenPrice);

        position.collateralAmount += collateralDelta;
        position.sizeInUsd += sizeDeltaUsd;
        position.sizeInTokens += indexTokenDelta;

        _validateNonEmptyPosition(position);

        positions[msg.sender] = position;

        totalCollateral += collateralDelta;
        if (isLong) {
            openInterestLong += sizeDeltaUsd;
            openInterestTokensLong += indexTokenDelta;
        } else {
            openInterestShort += sizeDeltaUsd;
            openInterestTokensShort += indexTokenDelta;
        }

        _validateMaxUtilization();
    }

    function decreasePosition() external {
        // TODO
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        totalDeposits += assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal override {
        totalDeposits -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
        _validateMaxUtilization();
    }

    function getIndexPrice() public view returns (uint256) {
        return _getPriceFeedPrice(indexPriceFeed, indexFeedHeartbeatDuration, indexFeedFactor);
    }

    function getCollateralPrice() public view returns (uint256) {
        return _getPriceFeedPrice(collateralPriceFeed, collateralFeedHeartbeatDuration, collateralFeedFactor);
    }

    function _getPriceFeedPrice(IAggregatorV3 priceFeed, uint256 heartBeatDuration, uint256 feedFactor) internal view returns (uint256) {
        (
            /* uint80 roundID */,
            int256 price,
            /* uint256 startedAt */,
            uint256 timestamp,
            /* uint80 answeredInRound */
        ) = priceFeed.latestRoundData();

        if (price <= 0) revert Errors.InvalidFeedPrice(address(priceFeed), price);
        if (block.timestamp - timestamp > heartBeatDuration) {
            revert Errors.PriceFeedNotUpdated(address(indexPriceFeed), timestamp, heartBeatDuration);
        }

        uint256 adjustedPrice = price.toUint256() * feedFactor;

        return adjustedPrice;
    }

    function _validateNonEmptyPosition(Position memory position) internal {
        if (position.sizeInUsd == 0 || position.sizeInTokens == 0 || position.collateralAmount == 0) {
            revert Errors.EmptyPosition(position.sizeInUsd, position.sizeInTokens, position.collateralAmount);
        }
    }

    function _validateMaxUtilization() internal {
        uint256 indexTokenPrice = getIndexPrice();
        uint256 collateralTokenPrice = getCollateralPrice();

        // Reserved amount for shorts is short OI
        uint256 reservedForShorts = openInterestShort;

        // Reserved amount for longs is the current value of long positions
        uint256 reservedForLongs = openInterestTokensLong * indexTokenPrice;

        uint256 totalReserved = reservedForLongs + reservedForShorts;

        uint256 valueOfDeposits = totalDeposits * collateralTokenPrice;
        uint256 maxUtilizableDeposits = valueOfDeposits * maxUtilizationRatio / PRECISION;

        if (totalReserved > maxUtilizableDeposits) revert Errors.MaxUtilizationBreached(maxUtilizableDeposits, totalReserved);
    }

}
