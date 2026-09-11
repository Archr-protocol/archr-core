// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ILockerFeeMetric
 * @notice Exposes the running total of quote-currency trading fees a locker has
 * collected for a launched token.
 */
interface ILockerFeeMetric {
    /// @notice Cumulative quote-currency fees collected for the token since
    /// launch.
    /// @dev Includes value credited to the position by direct donation, not
    /// only fees earned from trades.
    function cumulativeQuoteFees(address token) external view returns (uint256);
}
