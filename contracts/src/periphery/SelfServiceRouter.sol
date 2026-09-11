// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

interface IKeeperJobs {
    function crank(address token) external returns (uint256, uint256);
    function process(address token) external returns (uint256, uint256);
    function claimFor(address token, address holder) external;
}

/**
 * @title SelfServiceRouter
 * @notice One-transaction self-service for holders when no keeper is running:
 * collect the token's fees, turn them into rewards, and claim them, in a single
 * call. The distributor's three jobs are permissionless by design but must be
 * called separately, so without this a holder needs three transactions and a
 * wallet that can order them.
 *
 * @dev Stateless and ownerless, and not part of the core. The
 * distributor pays the crank bounty and process skim to `msg.sender`, which is
 * this contract, so anything earned is swept to the caller before returning.
 * `crank` and `process` are attempted independently and may fail without costing
 * the user their claim.
 *
 * A deploy excludes this address from reward shares, which the distributor
 * accepts only before its first token registers.
 */
abstract contract SelfServiceRouterBase {
    using SafeERC20 for IERC20;

    IKeeperJobs public immutable distributor;

    /// Reentrancy latch: a hostile stock quote gets control inside the sweep,
    /// where a nested call would earn a fresh bounty and sweep it to itself.
    uint256 private _entered;

    event SelfServed(address indexed token, address indexed holder, bool cranked, bool processed);
    /// A sweep that could not deliver; the value stays for the next caller.
    event SweepFailed(address indexed currency, address indexed to, uint256 amount);

    error Reentrancy();

    modifier nonReentrant() {
        if (_entered == 1) revert Reentrancy();
        _entered = 1;
        _;
        _entered = 0;
    }

    constructor(IKeeperJobs _distributor) {
        distributor = _distributor;
    }

    /// @notice The currency this token's rewards are paid in.
    function _rewardCurrency(address token) internal view virtual returns (Currency);

    /// @notice Collect, process and claim for `holder` in one transaction.
    /// Proceeds go to `holder`; any keeper bounty or skim goes to the caller.
    function crankProcessClaim(address token, address holder) external nonReentrant {
        _crankProcessClaim(token, holder);
    }

    function _crankProcessClaim(address token, address holder) private {
        bool cranked;
        bool processed;
        try distributor.crank(token) {
            cranked = true;
        } catch {}

        // Shed the crank's token-side bounty before processing, so it reaches
        // whoever paid for the call rather than sitting here across the payout.
        _sweep(Currency.wrap(token), msg.sender);

        try distributor.process(token) {
            processed = true;
        } catch {}

        distributor.claimFor(token, holder);

        // Sweep last: the router must end every call empty. Sweeping the whole
        // balance also releases anything sent here by mistake.
        _sweep(Currency.wrap(token), msg.sender);
        _sweep(_rewardCurrency(token), msg.sender);

        emit SelfServed(token, holder, cranked, processed);
    }

    /// @notice The same, across several tokens. Latched once for the whole batch,
    /// so a hostile currency in one cannot re-enter into another.
    function crankProcessClaimMany(address[] calldata tokens, address holder) external nonReentrant {
        for (uint256 i; i < tokens.length; ++i) {
            _crankProcessClaim(tokens[i], holder);
        }
    }

    /// @dev Non-reverting: the sweep runs after `claimFor`, so a failed transfer
    /// here must not undo a claim that already succeeded. Tolerates no-return
    /// tokens and rejects an explicit `false`.
    function _sweep(Currency currency, address to) private {
        address t = Currency.unwrap(currency);
        if (t == address(0)) return;
        (bool ok, bytes memory ret) = t.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || ret.length < 32) return;
        uint256 bal = abi.decode(ret, (uint256));
        if (bal == 0) return;
        (bool sent, bytes memory out) = t.call(abi.encodeCall(IERC20.transfer, (to, bal)));
        if (sent && (out.length == 0 || (out.length >= 32 && abi.decode(out, (uint256)) != 0))) return;
        emit SweepFailed(t, to, bal);
    }
}

interface INativeDistributor {
    function weth() external view returns (Currency);
}

/// @notice Native cell: every token's rewards are paid in WETH.
contract NativeSelfServiceRouter is SelfServiceRouterBase {
    Currency public immutable weth;

    constructor(IKeeperJobs _distributor) SelfServiceRouterBase(_distributor) {
        weth = INativeDistributor(address(_distributor)).weth();
    }

    function _rewardCurrency(address) internal view override returns (Currency) {
        return weth;
    }
}

interface IStockDistributor {
    function quoteOf(address token) external view returns (Currency);
}

/// @notice Stock cell: rewards are paid in that launch's own stock quote.
contract StockSelfServiceRouter is SelfServiceRouterBase {
    constructor(IKeeperJobs _distributor) SelfServiceRouterBase(_distributor) {}

    function _rewardCurrency(address token) internal view override returns (Currency) {
        return IStockDistributor(address(distributor)).quoteOf(token);
    }
}
