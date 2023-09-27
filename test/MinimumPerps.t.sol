// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/MinimumPerps.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {MockERC20} from "./Mock/MockERC20.sol";
import {MockAggregatorV3} from "./Mock/MockAggregatorV3.sol";
import {IAggregatorV3} from "../src/Interfaces/IAggregatorV3.sol";
import {Errors} from "../src/Errors.sol";
import {IOracle, Oracle} from "../src/Oracle.sol";

contract MinimumPerpsTest is Test {
    MinimumPerps public minimumPerps;

    address public alice = address(1);
    address public bob = address(2);

    MockERC20 public USDC;
    MockERC20 public BTC;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    string public constant name = "MinPerps";
    string public constant symbol = "MP";
    MockAggregatorV3 public btcFeed;
    MockAggregatorV3 public usdcFeed;
    uint8 public constant feedDecimals = 8;
    uint256 public constant heartbeat = 3600;

    // (50_000 * 1e30) / (50_000 * 1e8 * priceFeedFactor) = 1e8
    // E.g. $50,000 converts to 1 Bitcoin (8 decimals) when the price is $50,000 per BTC
    // => priceFeedFactor = 1e14
    uint256 public constant btcPriceFeedFactor = 1e14;

    uint256 public constant usdcPriceFeedFactor = 1e16;

    function setUp() public {
        USDC = new MockERC20("USDC", "USDC", 6);
        BTC = new MockERC20("BTC", "BTC", 8);

        // deploy mockAggregator for BTC
        btcFeed = new MockAggregatorV3(
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
        usdcFeed = new MockAggregatorV3(
            feedDecimals, //decimals
            "USDC", //description
            1, //version
            0, //roundId
            int256(1 * 10**feedDecimals), //answer
            0, //startedAt
            0, //updatedAt
            0 //answeredInRound
        );

        IOracle oracleContract = new Oracle();

        oracleContract.updatePricefeedConfig(
            address(USDC), 
            IAggregatorV3(usdcFeed), 
            heartbeat, 
            usdcPriceFeedFactor
        );

        oracleContract.updatePricefeedConfig(
            address(BTC), 
            IAggregatorV3(btcFeed), 
            heartbeat, 
            btcPriceFeedFactor
        );

        minimumPerps = new MinimumPerps(
            name, 
            symbol, 
            address(BTC),
            IERC20(USDC),
            IOracle(oracleContract),
            0 // Borrowing fees deactivated by default
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

    function test_decreaseNoPnl() public {
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

        // Bob has a position with the following:
        //  - Size in dollars of 100e30
        //  - Size in tokens of .002 WBTC (2e5)
        //  - Collateral of 50e6 USDC
        MinimumPerps.Position memory bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 100e30);

        assertEq(bobPosition.sizeInTokens, 2e5);
        assertEq(bobPosition.collateralAmount, 50e6);

        // Bob decreases his position size by 50%
        minimumPerps.decreasePosition(true, 50 * 1e30, 0);

        bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 50e30);

        assertEq(bobPosition.sizeInTokens, 1e5);
        assertEq(bobPosition.collateralAmount, 50e6);

        // Bob decreases his collateral by 50%
        minimumPerps.decreasePosition(true, 0, 25e6);

        bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 50e30);

        assertEq(bobPosition.sizeInTokens, 1e5);
        assertEq(bobPosition.collateralAmount, 25e6);

        // Bob closes his position
        minimumPerps.decreasePosition(true, 50e30, 0);

        bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 0);

        assertEq(bobPosition.sizeInTokens, 0);
        assertEq(bobPosition.collateralAmount, 0);
    }


    function test_decreaseProfitLong() public {
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

        // Bob has a position with the following:
        //  - Size in dollars of 100e30
        //  - Size in tokens of .002 WBTC (2e5)
        //  - Collateral of 50e6 USDC
        MinimumPerps.Position memory bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 100e30);

        assertEq(bobPosition.sizeInTokens, 2e5);
        assertEq(bobPosition.collateralAmount, 50e6);

        // Price of BTC rises 20%
        btcFeed.setPrice(int256(60_000 * 10**feedDecimals));

        uint256 bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob decreases his position size by 50%
        minimumPerps.decreasePosition(true, 50 * 1e30, 0);

        uint256 bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);

        // Bob's total profit is $20, therefore when decreasing by 50% he should receive 10 USDC
        assertEq(bobUsdcBalAfter - bobUsdcBalBefore, 10e6);

        bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 50e30);

        assertEq(bobPosition.sizeInTokens, 1e5);
        assertEq(bobPosition.collateralAmount, 50e6);

        bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob decreases his collateral by 50%
        minimumPerps.decreasePosition(true, 0, 25e6);

        bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);
        // No profit is realized as no size is decreased, but Bob receives back his collateral
        assertEq(bobUsdcBalAfter, bobUsdcBalBefore + 25e6);

        bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 50e30);

        assertEq(bobPosition.sizeInTokens, 1e5);
        assertEq(bobPosition.collateralAmount, 25e6);

        bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob closes his position
        minimumPerps.decreasePosition(true, 50e30, 0);

        bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);

        // Bob realizes the remainder 10 USDC in profit + the rest of his collateral
        assertEq(bobUsdcBalAfter - bobUsdcBalBefore, 10e6 + 25e6);

        bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 0);

        assertEq(bobPosition.sizeInTokens, 0);
        assertEq(bobPosition.collateralAmount, 0);
    }


    function test_decreaseLossLong() public {
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

        // Bob has a position with the following:
        //  - Size in dollars of 100e30
        //  - Size in tokens of .002 WBTC (2e5)
        //  - Collateral of 50e6 USDC
        MinimumPerps.Position memory bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 100e30);

        assertEq(bobPosition.sizeInTokens, 2e5);
        assertEq(bobPosition.collateralAmount, 50e6);


        // Price of BTC falls 20% -> Bob has 20 USDC of loss
        btcFeed.setPrice(int256(40_000 * 10**feedDecimals));

        uint256 bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob decreases his position size by 50%
        minimumPerps.decreasePosition(true, 50 * 1e30, 0);

        uint256 bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);

        // No profit was realized, losses deducted from collateral
        assertEq(bobUsdcBalBefore, bobUsdcBalAfter);

        bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 50e30);

        assertEq(bobPosition.sizeInTokens, 1e5);

        // Collateral is decreased by 50% of losses, e.g. 10 USDC
        assertEq(bobPosition.collateralAmount, 40e6);

        bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob decreases his collateral by 50%
        minimumPerps.decreasePosition(true, 0, 20e6);

        bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);

        // Half of collateral received
        assertEq(bobUsdcBalAfter - bobUsdcBalBefore, 20e6);

        bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 50e30);

        assertEq(bobPosition.sizeInTokens, 1e5);
        assertEq(bobPosition.collateralAmount, 20e6);

        bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob closes his position
        minimumPerps.decreasePosition(true, 50e30, 0);

        bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);

        // Received is remaining collateral minus 10 USDC losses
        assertEq(bobUsdcBalAfter - bobUsdcBalBefore, 10e6);

        bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 0);

        assertEq(bobPosition.sizeInTokens, 0);
        assertEq(bobPosition.collateralAmount, 0);
    }


    function test_decreaseProfitShort() public {
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
        minimumPerps.increasePosition(false, 100 * 1e30, 50e6);

        // Bob has a position with the following:
        //  - Size in dollars of 100e30
        //  - Size in tokens of .002 WBTC (2e5)
        //  - Collateral of 50e6 USDC
        MinimumPerps.Position memory bobPosition = minimumPerps.getPosition(false, bob);
        assertEq(bobPosition.sizeInUsd, 100e30);

        assertEq(bobPosition.sizeInTokens, 2e5);
        assertEq(bobPosition.collateralAmount, 50e6);

        // Price of BTC falls 20%, Bob is in profit 20 USDC
        btcFeed.setPrice(int256(40_000 * 10**feedDecimals));

        uint256 bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob decreases his position size by 50%
        minimumPerps.decreasePosition(false, 50 * 1e30, 0);

        uint256 bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);

        // Bob's total profit is $20, therefore when decreasing by 50% he should receive 10 USDC
        assertEq(bobUsdcBalAfter - bobUsdcBalBefore, 10e6);

        bobPosition = minimumPerps.getPosition(false, bob);
        assertEq(bobPosition.sizeInUsd, 50e30);

        assertEq(bobPosition.sizeInTokens, 1e5);
        assertEq(bobPosition.collateralAmount, 50e6);

        bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob decreases his collateral by 50%
        minimumPerps.decreasePosition(false, 0, 25e6);

        bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);
        // No profit is realized as no size is decreased, but Bob receives back his collateral
        assertEq(bobUsdcBalAfter, bobUsdcBalBefore + 25e6);
        bobPosition = minimumPerps.getPosition(false, bob);
        assertEq(bobPosition.sizeInUsd, 50e30);

        assertEq(bobPosition.sizeInTokens, 1e5);
        assertEq(bobPosition.collateralAmount, 25e6);

        bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob closes his position
        minimumPerps.decreasePosition(false, 50e30, 0);

        bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);

        // Bob realizes the remainder 10 USDC in profit + the rest of his collateral
        assertEq(bobUsdcBalAfter - bobUsdcBalBefore, 10e6 + 25e6);

        bobPosition = minimumPerps.getPosition(false, bob);
        assertEq(bobPosition.sizeInUsd, 0);

        assertEq(bobPosition.sizeInTokens, 0);
        assertEq(bobPosition.collateralAmount, 0);
    }


    function test_decreaseLossShort() public {
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
        minimumPerps.increasePosition(false, 100 * 1e30, 50e6);

        // Bob has a position with the following:
        //  - Size in dollars of 100e30
        //  - Size in tokens of .002 WBTC (2e5)
        //  - Collateral of 50e6 USDC
        MinimumPerps.Position memory bobPosition = minimumPerps.getPosition(false, bob);
        assertEq(bobPosition.sizeInUsd, 100e30);

        assertEq(bobPosition.sizeInTokens, 2e5);
        assertEq(bobPosition.collateralAmount, 50e6);

        // Price of BTC rises 20% -> Bob has 20 USDC of loss
        btcFeed.setPrice(int256(60_000 * 10**feedDecimals));

        uint256 bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob decreases his position size by 50%
        minimumPerps.decreasePosition(false, 50 * 1e30, 0);

        uint256 bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);

        // No profit was realized, losses deducted from collateral
        assertEq(bobUsdcBalBefore, bobUsdcBalAfter);

        bobPosition = minimumPerps.getPosition(false, bob);
        assertEq(bobPosition.sizeInUsd, 50e30);

        assertEq(bobPosition.sizeInTokens, 1e5);

        // Collateral is decreased by 50% of losses, e.g. 10 USDC
        assertEq(bobPosition.collateralAmount, 40e6);

        bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob decreases his collateral by 50%
        minimumPerps.decreasePosition(false, 0, 20e6);

        bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);

        // Half of collateral received
        assertEq(bobUsdcBalAfter - bobUsdcBalBefore, 20e6);

        bobPosition = minimumPerps.getPosition(false, bob);
        assertEq(bobPosition.sizeInUsd, 50e30);

        assertEq(bobPosition.sizeInTokens, 1e5);
        assertEq(bobPosition.collateralAmount, 20e6);

        bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);

        // Bob closes his position
        minimumPerps.decreasePosition(false, 50e30, 0);

        bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);

        // Received is remaining collateral minus 10 USDC losses
        assertEq(bobUsdcBalAfter - bobUsdcBalBefore, 10e6);

        bobPosition = minimumPerps.getPosition(false, bob);
        assertEq(bobPosition.sizeInUsd, 0);

        assertEq(bobPosition.sizeInTokens, 0);
        assertEq(bobPosition.collateralAmount, 0);
    }


    function test_liquidation() public {
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

        // Bob opens a 10x Long with 50 USDC as collateral
        USDC.approve(address(minimumPerps), 50e6);
        minimumPerps.increasePosition(true, 100 * 1e30, 10e6);

        vm.stopPrank();

        // Bob has a position with the following:
        //  - Size in dollars of 100e30
        //  - Size in tokens of .002 WBTC (2e5)
        //  - Collateral of 50e6 USDC
        MinimumPerps.Position memory bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 100e30);

        assertEq(bobPosition.sizeInTokens, 2e5);
        assertEq(bobPosition.collateralAmount, 10e6);

        // Bob is not liquidatable initially
        assertFalse(minimumPerps.isPositionLiquidatable(bob, true));

        // Price of BTC falls 6%, Bob is in loss 6 USDC
        btcFeed.setPrice(int256(47_000 * 10**feedDecimals));

        // Now bob is liquidatable
        assertTrue(minimumPerps.isPositionLiquidatable(bob, true));

        // Alice executes the liquidation, alice receives 2% of bob's collateral before losses
        // Bob has 10 USDC of collateral, therefore alice receives 0.2 USDC
        uint256 aliceUsdcBalBefore = IERC20(USDC).balanceOf(alice);
        uint256 bobUsdcBalBefore = IERC20(USDC).balanceOf(bob);
        uint256 totalDepositsBefore = minimumPerps.totalDeposits();

        vm.prank(alice);
        minimumPerps.liquidate(bob, true);

        uint256 aliceUsdcBalAfter = IERC20(USDC).balanceOf(alice);
        uint256 bobUsdcBalAfter = IERC20(USDC).balanceOf(bob);
        uint256 totalDepositsAfter = minimumPerps.totalDeposits();

        // Alice received 0.2 USDC
        assertEq(aliceUsdcBalAfter - aliceUsdcBalBefore, 2e5);

        // Bob received back the remaining collateral
        // Bob had 10 USDC collateral, 6 USDC of losses, 0.2 USDC of liquidatorFee
        // 10 - 6.2 = 3.8 USDC
        assertEq(bobUsdcBalAfter - bobUsdcBalBefore, 38e5);

        // Bob's losses of 6 USDC were paid out to the LPs
        assertEq(totalDepositsAfter - totalDepositsBefore, 6e6);

        aliceUsdcBalBefore = IERC20(USDC).balanceOf(alice);

        vm.prank(alice);
        minimumPerps.redeem(200e6, alice, alice);

        aliceUsdcBalAfter = IERC20(USDC).balanceOf(alice);

        // Alice withdraws her deposits + gains from bob's lossses (minor imprecision)
        assertEq(aliceUsdcBalAfter - aliceUsdcBalBefore, 205999999);

        // Bob's position is now closed
        bobPosition = minimumPerps.getPosition(true, bob);
        assertEq(bobPosition.sizeInUsd, 0);
        assertEq(bobPosition.sizeInTokens, 0);
        assertEq(bobPosition.collateralAmount, 0);
    }


}
