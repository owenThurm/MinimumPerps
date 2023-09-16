// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/MinimumPerps.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {MockERC20} from "./Mock/MockERC20.sol";
import {MockAggregatorV3} from "./Mock/MockAggregatorV3.sol";
import {IAggregatorV3} from "../src/Interfaces/IAggregatorV3.sol";
import {Errors} from "../src/Errors.sol";

contract MinimumPerpsTest is Test {
    MinimumPerps public minimumPerps;

    address public alice = address(1);
    address public bob = address(2);

    MockERC20 public USDC;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    string public constant name = "MinPerps";
    string public constant symbol = "MP";
    MockAggregatorV3 public btcOracle;
    MockAggregatorV3 public usdcOracle;
    uint8 public constant feedDecimals = 8;
    uint256 public constant heartbeat = 3600;

    // (50_000 * 1e30) / (50_000 * 1e8 * priceFeedFactor) = 1e8
    // E.g. $50,000 converts to 1 Bitcoin (8 decimals) when the price is $50,000 per BTC
    // => priceFeedFactor = 1e14
    uint256 public constant btcPriceFeedFactor = 1e14;

    uint256 public constant usdcPriceFeedFactor = 1e16;

    function setUp() public {
        USDC = new MockERC20("USDC", "USDC", 6);

        // deploy mockAggregator for BTC
        btcOracle = new MockAggregatorV3(
            feedDecimals, //decimals
            "BTC", //description
            1, //version
            0, //roundId
            int256(50_000 * 10**feedDecimals), //answer
            0, //startedAt
            0, //updatedAt
            0 //answeredInRound
        );


        // deploy mockAggregator for USDC
        usdcOracle = new MockAggregatorV3(
            feedDecimals, //decimals
            "USDC", //description
            1, //version
            0, //roundId
            int256(1 * 10**feedDecimals), //answer
            0, //startedAt
            0, //updatedAt
            0 //answeredInRound
        );

        minimumPerps = new MinimumPerps(
            name, 
            symbol, 
            IERC20(USDC), 
            IAggregatorV3(btcOracle),
            heartbeat,
            btcPriceFeedFactor,
            IAggregatorV3(usdcOracle),
            heartbeat,
            usdcPriceFeedFactor
        );
    }


    function test_deposit() public {
        USDC.mint(alice, 100e6); // 100 USDC for Alice

        vm.startPrank(alice);
        USDC.approve(address(minimumPerps), 100e6);
        minimumPerps.deposit(100e6, alice);

        uint256 vaultBalance = USDC.balanceOf(address(minimumPerps));
        assertEq(vaultBalance, 100e6);

        uint256 netBalance = minimumPerps.totalAssets();
        assertEq(netBalance, 100e6);
    }


    function test_increase() public {
        USDC.mint(alice, 200e6); // 100 USDC for Alice to deposit

        vm.startPrank(alice);
        USDC.approve(address(minimumPerps), 200e6);
        minimumPerps.deposit(200e6, alice);

        uint256 vaultBalance = USDC.balanceOf(address(minimumPerps));
        assertEq(vaultBalance, 200e6);

        uint256 netBalance = minimumPerps.totalAssets();
        assertEq(netBalance, 200e6);

        vm.stopPrank();

        USDC.mint(bob, 50e6); // 50 USDC for Bob to use as collateral

        vm.startPrank(bob);

        // Bob opens a 2x Long with 50 USDC as collateral
        USDC.approve(address(minimumPerps), 50e6);
        minimumPerps.increasePosition(true, 100 * 1e30, 50e6);

        vm.stopPrank();

        // Bob has a position with the following:
        //  - Size in dollars of 100e30
        //  - Size in tokens of .002 WBTC (2e5)
        //  - Collateral of 50e6 USDC
        MinimumPerps.Position memory bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 100e30);

        assertEq(bobPosition.sizeInTokens, 2e5);
        assertEq(bobPosition.collateralAmount, 50e6);

        // The market holds 150 USDC in total
        vaultBalance = USDC.balanceOf(address(minimumPerps));
        assertEq(vaultBalance, 250e6);

        // 50 USDC of collateral
        assertEq(minimumPerps.totalCollateral(), 50*1e6);

        // 100 USDC of deposits
        assertEq(minimumPerps.totalDeposits(), 200*1e6);

        // Collateral is not included in the balance of the market that belongs to depositors
        netBalance = minimumPerps.totalAssets();
        assertEq(netBalance, 200e6);

        vm.startPrank(alice);
        // Alice cannot withdraw deposits as they are reserved
        vm.expectRevert(abi.encodeWithSelector(Errors.MaxUtilizationBreached.selector, 50*1e30, 100*1e30));
        minimumPerps.withdraw(100e6, alice, alice);

        vm.stopPrank();

        // Bob cannot increase position as max utilization is reached
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Errors.MaxUtilizationBreached.selector, 100*1e30, 200*1e30));
        minimumPerps.increasePosition(true, 100*1e30, 0);

        vm.stopPrank();

    }

}
