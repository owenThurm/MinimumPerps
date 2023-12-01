// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MinimumPerps} from "../MinimumPerpsFuzzed.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import {MockERC20} from "../../test/Mock/MockERC20.sol";
import {MockAggregatorV3} from "../../test/Mock/MockAggregatorV3.sol";

import "forge-std/Test.sol";

contract MinimumPerpsHandler is Test {

    MinimumPerps public minimumPerps;
    MockERC20 public usdc;
    MockAggregatorV3 public pricefeed;

    constructor(MinimumPerps _minimumPerps, MockERC20 _usdc, MockAggregatorV3 _pricefeed) {
        minimumPerps = _minimumPerps;
        usdc = _usdc;
        pricefeed = _pricefeed;
    }

    function deposit(uint256 assets, address receiver) external {
        bound(assets, 0, 1e20);
        usdc.mint(address(this), assets);

        usdc.approve(address(minimumPerps), assets);

        minimumPerps.deposit(assets, receiver);
    }

    function withdraw(uint256 amount) external {
        minimumPerps.withdraw(amount, msg.sender, msg.sender);
    }

    function increasePosition(bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta) external {
        usdc.mint(address(this), collateralDelta);

        usdc.approve(address(minimumPerps), collateralDelta);

        minimumPerps.increasePosition(isLong, sizeDeltaUsd, collateralDelta, msg.sender);
    }

    function decreasePosition(bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta) external {
        minimumPerps.decreasePosition(isLong, sizeDeltaUsd, collateralDelta, msg.sender);
    }

    function liquidate(bool isLong) external {
        minimumPerps.liquidate(msg.sender, isLong);
    }

    function setPrice(uint256 seed) external {
        // BTC price in the range $45000-$55000
        uint256 newPrice = bound(seed, 45_000e8, 55_000e8); 

        pricefeed.setPrice(int256(newPrice));
    }


}