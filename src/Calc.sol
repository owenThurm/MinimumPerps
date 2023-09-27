// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

library Calc {

    function roundUpDivision(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }
}