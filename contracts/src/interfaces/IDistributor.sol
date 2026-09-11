// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title ICheckpointReceiver
 * @notice Callback a launched token invokes on every transfer so the distributor
 * can keep each holder's reward share in sync with their balance.
 */
interface ICheckpointReceiver {
    /// @notice Sync reward shares for the sender and recipient of a transfer.
    function checkpoint(address from, address to) external;
}

/**
 * @title IDistributor
 * @notice Distributor interface used by the launchpad and locker: registers a
 * token's reward configuration and deposits the holder share of trading fees.
 */
interface IDistributor is ICheckpointReceiver {
    /// @notice How incoming fees are split: direct quote rewards,
    /// buyback-and-reflect, buyback-and-burn, and the share of token fees
    /// reflected rather than burned. The holder share itself lives in the
    /// locker's `Launch` record, which is the canonical copy.
    struct RewardConfig {
        uint16 ethRewardsBps;
        uint16 buybackReflectBps;
        uint16 buybackBurnBps;

        uint16 tokenReflectBps;
    }

    /// @notice Register a launched token's pool and reward configuration.
    function register(address token, PoolKey calldata poolKey, RewardConfig calldata config) external;

    /// @notice Record the holder share of collected quote and token fees as pending.
    function deposit(address token, uint256 wethAmount, uint256 tokenAmount) external;

    /// @notice Whether a deposit made now could ever be distributed. False when
    /// the token's rewards route through the per-share accumulator and there are
    /// too few shares to divide by; always true for a burn-only pool. The locker
    /// reads this and declines to pull, leaving the fees in the locked position.
    function canAccrue(address token) external view returns (bool);
}
