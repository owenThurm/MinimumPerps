// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {MinimumPerps} from "../MinimumPerpsFuzzed.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";

import {MockERC20} from "../../test/Mock/MockERC20.sol";


contract MinimumPerpsHandler {

    MinimumPerps public minimumPerps;
    MockERC20 public usdc;

    constructor(MinimumPerps _minimumPerps, MockERC20 _usdc) {
        minimumPerps = _minimumPerps;
        usdc = _usdc;
    }

    function deposit(uint256 assets, address receiver) external {
        require(assets < 1e40);
        usdc.mint(address(this), assets);

        usdc.approve(address(minimumPerps), assets);

        minimumPerps.deposit(assets, receiver);
    }

    function increasePosition(bool isLong, uint256 sizeDeltaUsd, uint256 collateralDelta) external {
        usdc.mint(address(this), collateralDelta);

        usdc.approve(address(minimumPerps), collateralDelta);

        minimumPerps.increasePosition(isLong, sizeDeltaUsd, collateralDelta, msg.sender);
    }


}