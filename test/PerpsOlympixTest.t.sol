pragma solidity ^0.8.0;

import "../src/MinimumPerps.sol";
import "forge-std/Test.sol";
import {OlympixUnitTest} from "./OlympixUnitTest.sol";

contract PerpsOlympixTest is OlympixUnitTest("MinimumPerps") {
    address alice = address(0x3);
    address bob = address(0x4);
    address david = address(0x5);

    MinimumPerps perps;

    function setUp() public {
        perps = new MinimumPerps(
            "TST", 
            "TST", 
            address(1),
            IERC20(address(1)),
            IOracle(address(2)),
            0 // Borrowing fees deactivated by default
        );
        vm.deal(alice, 1000);
        vm.deal(bob, 10 ether);
    }
}