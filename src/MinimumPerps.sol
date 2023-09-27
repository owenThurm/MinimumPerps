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
import {IOracle} from "./Oracle.sol";
import {Calc} from "./Calc.sol";
import {SignedMath} from "openzeppelin-contracts/contracts/utils/math/SignedMath.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

import "forge-std/Test.sol";

contract MinimumPerps is ERC4626, Ownable2Step {
    using SignedMath for int256;
    using SafeCast for int256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    struct Position {
        uint256 sizeInUsd;
        uint256 sizeInTokens;
        uint256 collateralAmount;
        uint256 lastUpdatedAt;
    }

    uint256 public constant PRECISION = 1e30;

    IOracle public oracle;
    address public indexToken;

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

    // Max leverage is 20x
    uint256 public maxLeverage = 20e30;

    uint256 public liquidationFeeBp = 200; // 2%
    uint256 public constant BASIS_POINTS = 10_000;

    uint256 public borrowingPerSharePerSecond;
    uint256 public constant MAX_BORROWING_RATE = 3170979198376458650431; // 10% per year

    constructor(
        string memory _name, 
        string memory _symbol, 
        address _indexToken,
        IERC20 _collateralToken, 
        IOracle _oracle,
        uint256 _borrowingPerSharePerSecond
    ) ERC20(_name, _symbol) ERC4626(_collateralToken) {
        indexToken = _indexToken;
        oracle = _oracle;
        _setBorrowingPerSharePerSecond(_borrowingPerSharePerSecond);
    }

    function setBorrowingPerSharePerSecond(uint256 _borrowingPerSharePerSecond) external onlyOwner {
        _setBorrowingPerSharePerSecond(_borrowingPerSharePerSecond);
    }

    function _setBorrowingPerSharePerSecond(uint256 _borrowingPerSharePerSecond) internal {
        if (_borrowingPerSharePerSecond > MAX_BORROWING_RATE) revert Errors.InvalidBorrowingFeeRate(_borrowingPerSharePerSecond);
        borrowingPerSharePerSecond = _borrowingPerSharePerSecond;
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

        int256 netTraderPnlInCollateral = (traderPnlLong + traderPnlShort) / getCollateralPrice().toInt256();

        if (netTraderPnlInCollateral > 0) {
            if (netTraderPnlInCollateral.toUint256() > _totalDeposits) revert Errors.TraderPnlExceedsDeposits();
            return _totalDeposits - netTraderPnlInCollateral.toUint256();
        } else return _totalDeposits + (-netTraderPnlInCollateral).toUint256();
    }


    function increasePosition(bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta) external {
        if (collateralDelta > 0) IERC20(asset()).safeTransferFrom(msg.sender, address(this), collateralDelta);

        mapping(address => Position) storage positions = isLong ? longPositions : shortPositions;

        Position memory position = positions[msg.sender];

        uint256 indexTokenPrice = getIndexPrice();
        uint256 indexTokenDelta = isLong ? sizeDeltaUsd / indexTokenPrice : Math.ceilDiv(sizeDeltaUsd, indexTokenPrice);

        uint256 pendingBorrowingFees = _calculateBorrowingFees(position);

        position.collateralAmount += collateralDelta;
        position.sizeInUsd += sizeDeltaUsd;
        position.sizeInTokens += indexTokenDelta;

        position.collateralAmount -= pendingBorrowingFees;
        totalDeposits += pendingBorrowingFees;

        position.lastUpdatedAt = block.timestamp;

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

    function decreasePosition(bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta) external {
        _decreasePosition(msg.sender, isLong, sizeDeltaUsd, collateralDelta, false);
        if (isPositionLiquidatable(msg.sender, isLong)) revert Errors.PositionIsLiquidatable();
    }

    function isPositionLiquidatable(address trader, bool isLong) public view returns (bool) {
        Position memory position = isLong ? longPositions[trader] : shortPositions[trader];
        if (position.sizeInUsd == 0) return false;
        uint256 collateralValue = position.collateralAmount * getCollateralPrice();

        // Account for borrowing fees
        uint256 borrowingFees = _calculateBorrowingFees(position);
        if (collateralValue <= borrowingFees) return true;
        else collateralValue -= borrowingFees;

        // Account for PnL
        (int256 positionPnl, ) = _calculateRealizedPnl(position, isLong, position.sizeInUsd);
        if (positionPnl <= 0) {
            uint256 positionLoss = positionPnl.abs();
            if (collateralValue <= positionLoss) return true;
            collateralValue -= positionLoss;
        } else {
            collateralValue += positionPnl.abs();
        }

        return position.sizeInUsd * 1e30 / collateralValue > maxLeverage;
    }

    function liquidate(address trader, bool isLong) external {
        if (!isPositionLiquidatable(trader, isLong)) revert Errors.PositionNotLiquidatable();
        mapping(address => Position) storage positions = isLong ? longPositions : shortPositions;

        Position memory position = positions[trader];

        _decreasePosition(trader, isLong, position.sizeInUsd, 0, true);
    }

    function _decreasePosition(address trader, bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta, bool isLiquidation) internal {
        mapping(address => Position) storage positions = isLong ? longPositions : shortPositions;

        Position memory position = positions[trader];

        uint256 collateralTokenPrice = getCollateralPrice();

        (int256 realizedPnl, uint256 sizeDeltaTokens) = _calculateRealizedPnl(position, isLong, sizeDeltaUsd);

        uint256 pendingBorrowingFees = _calculateBorrowingFees(position);

        // decrease the size & collateral
        position.sizeInTokens -= sizeDeltaTokens;
        position.sizeInUsd -= sizeDeltaUsd;
        position.collateralAmount -= collateralDelta;

        if (pendingBorrowingFees > position.collateralAmount && isLiquidation) { // Allow liquidations to insolvently close
            pendingBorrowingFees = position.collateralAmount;
            position.collateralAmount = 0;
            totalDeposits += pendingBorrowingFees;
        } else {
            if (position.collateralAmount < pendingBorrowingFees) revert Errors.InsufficientCollateralForBorrowingFees(pendingBorrowingFees, position.collateralAmount);
            position.collateralAmount -= pendingBorrowingFees;
            totalDeposits += pendingBorrowingFees;
        }

        if (isLong) {
            openInterestLong -= sizeDeltaUsd;
            openInterestTokensLong -= sizeDeltaTokens;
        } else {
            openInterestShort -= sizeDeltaUsd;
            openInterestTokensShort -= sizeDeltaTokens;
        }

        // Choice is to take the liquidationFee at a higher priority than the LP payout during liquidation
        if (isLiquidation) {
            uint256 liquidationFeeAmount = position.collateralAmount * liquidationFeeBp / BASIS_POINTS;
            position.collateralAmount -= liquidationFeeAmount;
            IERC20(asset()).safeTransfer(msg.sender, liquidationFeeAmount);
        }

        if (realizedPnl < 0) {
            uint256 positionLossInCollateral = realizedPnl.abs() / collateralTokenPrice;
            if (isLiquidation && position.collateralAmount < positionLossInCollateral) { // Allow insolvent liquidations
                positionLossInCollateral = position.collateralAmount;
                position.collateralAmount = 0; 
            }
            else if (position.collateralAmount < positionLossInCollateral) revert Errors.InsufficientCollateralForLoss(positionLossInCollateral, position.collateralAmount);
            position.collateralAmount -= positionLossInCollateral;
            totalDeposits += positionLossInCollateral; // LPs paid losses
        }

        uint256 outputAmount;

        if (realizedPnl > 0) {
            outputAmount += realizedPnl.toUint256() / collateralTokenPrice;

            // LPs pay out the trader
            totalDeposits -= outputAmount;
        }

        if (collateralDelta > 0) outputAmount += collateralDelta;
        if (position.sizeInTokens == 0 || position.sizeInUsd == 0) {
            outputAmount += position.collateralAmount;
            delete positions[trader];
        } else {
            position.lastUpdatedAt = block.timestamp;
            positions[trader] = position;
        }

        if (outputAmount > 0) IERC20(asset()).safeTransfer(trader, outputAmount);
    }

    function _calculateRealizedPnl(Position memory position, bool isLong, uint256 sizeDeltaUsd) internal view returns (int256 realizedPnl, uint256 sizeDeltaTokens) {
        int256 currentPositionValue = (position.sizeInTokens * getIndexPrice()).toInt256();
        int256 totalPnl = isLong ? currentPositionValue - position.sizeInUsd.toInt256() : position.sizeInUsd.toInt256() - currentPositionValue;

        realizedPnl = totalPnl * sizeDeltaUsd.toInt256() / position.sizeInUsd.toInt256();
        if (position.sizeInUsd == sizeDeltaUsd) {
            sizeDeltaTokens = position.sizeInTokens;
        } else if (isLong) {
            sizeDeltaTokens = Calc.roundUpDivision(position.sizeInTokens * sizeDeltaUsd, position.sizeInUsd);
        } else {
            sizeDeltaTokens = position.sizeInTokens * sizeDeltaUsd / position.sizeInUsd;
        }
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

    function getPendingBorrowingFees(address trader, bool isLong) external view returns (uint256) {
        Position memory position = isLong ? longPositions[trader] : shortPositions[trader];
        return _calculateBorrowingFees(position);
    }

    function _calculateBorrowingFees(Position memory position) internal view returns (uint256 pendingBorrowingFees) {
        uint256 pendingBorrowingFeesUsd = position.sizeInUsd * (block.timestamp - position.lastUpdatedAt) * borrowingPerSharePerSecond / 1e30;
        pendingBorrowingFees = pendingBorrowingFeesUsd / getCollateralPrice();
    }

    function getIndexPrice() public view returns (uint256) {
        return oracle.getTokenPrice(indexToken);
    }

    function getCollateralPrice() public view returns (uint256) {
        return oracle.getTokenPrice(asset());
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
