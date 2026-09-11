// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IMsgSender} from "@uniswap/v4-periphery/src/interfaces/IMsgSender.sol";

interface ILauncherSource {
    function launchpad() external view returns (address);
}

/**
 * @title LiquidityGate
 * @notice Uniswap v4 hook that locks a launch pool. Only the launchpad may
 * initialize the pool and only the locker may add liquidity; any attempt to
 * remove liquidity reverts, keeping the position permanently locked.
 */
contract LiquidityGate is BaseHook {
    address public immutable locker;

    address public immutable positionManager;

    error OnlyLocker();
    error OnlyLauncher();
    error LiquidityLockedForever();

    constructor(IPoolManager _poolManager, address _locker, address _positionManager) BaseHook(_poolManager) {
        locker = _locker;
        positionManager = _positionManager;
    }

    function launchpad() public view returns (address) {
        return ILauncherSource(locker).launchpad();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Only the launchpad may create a pool on this hook.
    function _beforeInitialize(address sender, PoolKey calldata, uint160)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != launchpad()) revert OnlyLauncher();
        return BaseHook.beforeInitialize.selector;
    }

    /// @notice Only the locker may add liquidity, whether directly or through the
    /// position manager acting on the locker's behalf.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender == locker) return BaseHook.beforeAddLiquidity.selector;
        if (sender == positionManager && _initiatedByLocker(sender)) {
            return BaseHook.beforeAddLiquidity.selector;
        }
        revert OnlyLocker();
    }

    /// @notice Reverts on any liquidity decrease, so the position can never be pulled.
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        if (params.liquidityDelta < 0) revert LiquidityLockedForever();
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /// @notice True if the position manager call was initiated by the locker.
    function _initiatedByLocker(address sender) private view returns (bool) {
        try IMsgSender(sender).msgSender() returns (address initiator) {
            return initiator == locker;
        } catch {
            return false;
        }
    }
}
