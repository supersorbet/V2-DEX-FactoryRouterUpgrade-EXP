// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import "./uniswap/IUniswapV2Pair.sol";

interface IPair is IUniswapV2Pair {
    function getLiquidityTrackRecord(address account) external view returns (uint112 liquidityTrackRecord0, uint112 liquidityTrackRecord1, uint32 timeLastUpdate);
    function swapFor0(uint amount0Out, address to) external; // support simple swap
    function swapFor1(uint amount1Out, address to) external; 
    function getReservesAndParameters() external view returns (uint112 reserve0, uint112 reserve1, uint16 swapFee);
    function getReservesSimple() external view returns (uint112, uint112);

    function swapFeeOverride() external view returns (uint16);
    function setSwapFeeOverride(uint16 newSwapFeeOverride) external;
    function getSwapFee() external view returns (uint16);
}