// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/MinimumPerpsFuzzed.sol";
import {IERC20} from "openzeppelin-contracts/contracts/interfaces/IERC20.sol";
import {MockERC20} from "./Mock/MockERC20.sol";
import {MockAggregatorV3} from "./Mock/MockAggregatorV3.sol";
import {IAggregatorV3} from "../src/Interfaces/IAggregatorV3.sol";
import {Errors} from "../src/Errors.sol";
import {IOracle, Oracle} from "../src/Oracle.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MinimumPerpsHandler} from "../src/Handler/MinimumPerpsHandler.sol";

contract MinimumPerpsTest is StdInvariant, Test {
    MinimumPerps public minimumPerps;
    MinimumPerpsHandler public minimumPerpsHandler;

    error TooMuchDeposits();

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

        minimumPerpsHandler = new MinimumPerpsHandler(
            minimumPerps,
            USDC,
            btcFeed
        );
        targetContract(address(minimumPerpsHandler));

        targetSender(bob);
        vm.prank(bob);
        minimumPerps.approve(address(minimumPerpsHandler), type(uint256).max);

        targetSender(alice);
        vm.prank(alice);
        minimumPerps.approve(address(minimumPerpsHandler), type(uint256).max);

        uint256 usdcLiquidityDeposit = 1_000_000e6;

        deal(address(USDC), bob, usdcLiquidityDeposit);
        vm.startPrank(bob);
        USDC.approve(address(minimumPerps), usdcLiquidityDeposit);
        minimumPerps.deposit(usdcLiquidityDeposit, bob);

        vm.stopPrank();

        deal(address(USDC), alice, usdcLiquidityDeposit);
        vm.startPrank(alice);
        USDC.approve(address(minimumPerps), usdcLiquidityDeposit);
        minimumPerps.deposit(usdcLiquidityDeposit, alice);

        vm.stopPrank();
    }

    function invariant_hitThis() public {
        assertTrue(minimumPerps.test() == 0);
    }

    function invariant_OINotOverutilized() public {
        uint256 depositedLiquidity = minimumPerps.totalDeposits();

        uint256 netOI = minimumPerps.openInterestLong() + minimumPerps.openInterestShort();

        uint256 collateralPrice = minimumPerps.getCollateralPrice();

        // Open interest should not be more than 50% of the available liquidity
        assert(netOI <= depositedLiquidity * collateralPrice / 2);
    }


}