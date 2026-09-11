// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {ILockerFeeMetric} from "../interfaces/ILockerFeeMetric.sol";
import {IDistributor} from "../interfaces/IDistributor.sol";

/**
 * @title StockLocker
 * @notice Permanently holds the launch liquidity position for each stock-quoted
 * token, collects its Uniswap v4 trading fees, and splits them between the
 * creator, treasury, and the holder/burn distributor share. Because the quote is
 * a stock token that can pause or block transfers, payouts that fail are recorded
 * as owed and can be retried later rather than reverting the collection.
 */
contract StockLocker is ILockerFeeMetric, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Launch {
        address creator;
        uint16 creatorBps;
        uint16 holdersBps;
        uint16 lpBps;
        int24 tickUpper;
        uint256 tokenId;
        address distributor;
        PoolKey poolKey;
    }

    IPositionManager public immutable positionManager;
    IPermit2 public immutable permit2;
    IPoolManager public immutable poolManager;
    address public immutable treasury;
    address public immutable deployer;
    address public launchpad;

    mapping(address token => Launch) public launches;
    mapping(address token => uint256) public override cumulativeQuoteFees;

    /// A quote payout the token refused, recorded per RECIPIENT. Only the
    /// treasury's leg is deferred this way, since the treasury is immutable and
    /// cannot go out of date between the failure and the retry.
    mapping(address quoteToken => mapping(address recipient => uint256)) public quoteOwed;

    mapping(address token => uint256) public deferredHolderQuote;

    /// A creator payout the quote refused, recorded per LAUNCH so
    /// `retryCreatorQuote` resolves the recipient when it is released rather than
    /// when it was deferred.
    mapping(address token => uint256) public deferredCreatorQuote;

    event LaunchLocked(address indexed token, address indexed creator, uint256 tokenId);
    event FeesCollected(address indexed token, uint256 quoteFees, uint256 tokenFees);
    event FeesCompounded(address indexed token, uint256 quoteAdded, uint256 tokenAdded, uint128 liquidity);
    /// Emitted when the compounding add did not go through; the liquidity share
    /// falls back into the normal split and the collection completes.
    event CompoundSkipped(address indexed token, uint256 quoteBudget, uint256 tokenBudget);
    /// Emitted when a collect declined to pull because the distributor has too
    /// few shares to divide by. The fees stay in the locked position and the
    /// next collect takes them.
    event CollectionDeferred(address indexed token);
    event QuotePayoutDeferred(address indexed quoteToken, address indexed recipient, uint256 amount);
    event QuotePayoutReleased(address indexed quoteToken, address indexed recipient, uint256 amount);
    event HolderQuoteDeferred(address indexed token, uint256 amount);
    event HolderQuoteReleased(address indexed token, uint256 amount);
    event CreatorQuoteDeferred(address indexed token, uint256 amount);
    event CreatorQuoteReleased(address indexed token, address indexed creator, uint256 amount);

    error AlreadyInitialized();
    error OnlyDeployer();
    error OnlyLaunchpad();
    error UnknownToken();
    error NothingOwed();
    error ZeroTreasury();
    error AccrualDeferred();

    constructor(IPositionManager _positionManager, IPermit2 _permit2, address _treasury) {
        if (_treasury == address(0)) revert ZeroTreasury();
        positionManager = _positionManager;
        permit2 = _permit2;
        treasury = _treasury;
        deployer = msg.sender;
        poolManager = IPoolManager(address(_positionManager.poolManager()));
    }

    /// @notice One-time wiring of the launchpad, callable only by the deployer.
    function initialize(address _launchpad) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (launchpad != address(0)) revert AlreadyInitialized();
        launchpad = _launchpad;
    }

    /// @notice Mints the full-range launch position held by this contract and
    /// records the token's fee split. Callable only by the launchpad.
    function lockLaunch(
        PoolKey calldata poolKey,
        address creator,
        int24 tickUpper,
        uint16 creatorBps,
        uint16 holdersBps,
        uint16 lpBps,
        address distributor,
        uint256 amount
    ) external returns (uint256 tokenId) {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        address token = Currency.unwrap(poolKey.currency1);

        IERC20(token).approve(address(permit2), amount);
        permit2.approve(token, address(positionManager), uint160(amount), uint48(block.timestamp));

        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount
        );

        tokenId = positionManager.nextTokenId();

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(poolKey, tickLower, tickUpper, liquidity, uint128(0), uint128(amount), address(this), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        launches[token] = Launch({
            creator: creator,
            creatorBps: creatorBps,
            holdersBps: holdersBps,
            lpBps: lpBps,
            tickUpper: tickUpper,
            tokenId: tokenId,
            distributor: distributor,
            poolKey: poolKey
        });
        emit LaunchLocked(token, creator, tokenId);
    }

    /// Timelocked handover of a launch's creator payout. The current creator
    /// proposes, the change matures after `CREATOR_TRANSFER_DELAY`, and anyone may
    /// then apply it within `CREATOR_TRANSFER_WINDOW`. Only the creator can start
    /// or cancel one, and a cancel is only possible while the proposal matures.
    ///
    /// Fees already collected are unaffected; uncollected fees are not. They sit
    /// in the locked position and are attributed to whoever is `creator` when
    /// somebody calls `collect`, so a handover moves the whole uncollected
    /// backlog.
    struct PendingCreator {
        address to;
        uint64 readyAt;
        uint64 expiresAt;
    }

    uint256 public constant CREATOR_TRANSFER_DELAY = 1 days;
    uint256 public constant CREATOR_TRANSFER_WINDOW = 5 days;

    mapping(address token => PendingCreator) public pendingCreatorOf;

    event CreatorTransferStarted(address indexed token, address indexed from, address indexed to, uint64 readyAt);
    event CreatorTransferCancelled(address indexed token, address indexed to);
    event CreatorTransferred(address indexed token, address indexed from, address indexed to);

    error OnlyCreator();
    error ZeroCreator();
    error TransferNotReady();
    error TransferExpired();
    error NoPendingTransfer();

    /// @notice Propose a new recipient for this launch's creator fee share.
    /// Callable only by the current creator; replaces any pending proposal.
    function startCreatorTransfer(address token, address to) external {
        Launch storage l = launches[token];
        if (l.creator == address(0)) revert UnknownToken();
        if (msg.sender != l.creator) revert OnlyCreator();
        if (to == address(0)) revert ZeroCreator();
        uint64 readyAt = uint64(block.timestamp + CREATOR_TRANSFER_DELAY);
        uint64 expiresAt = uint64(block.timestamp + CREATOR_TRANSFER_DELAY + CREATOR_TRANSFER_WINDOW);
        pendingCreatorOf[token] = PendingCreator({to: to, readyAt: readyAt, expiresAt: expiresAt});
        emit CreatorTransferStarted(token, l.creator, to, readyAt);
    }

    /// @notice Abandon a pending handover. Callable by the current creator, which
    /// is what makes the timelock useful against a stolen key.
    function cancelCreatorTransfer(address token) external {
        Launch storage l = launches[token];
        if (msg.sender != l.creator) revert OnlyCreator();
        PendingCreator memory p = pendingCreatorOf[token];
        if (p.to == address(0)) revert NoPendingTransfer();
        delete pendingCreatorOf[token];
        emit CreatorTransferCancelled(token, p.to);
    }

    /// @notice Apply a matured handover. Callable by anyone once the delay has
    /// elapsed and before the window closes — the proposal is the creator's
    /// authorisation, and the delay is when it could have been withdrawn.
    function executeCreatorTransfer(address token) external {
        PendingCreator memory p = pendingCreatorOf[token];
        if (p.to == address(0)) revert NoPendingTransfer();
        if (block.timestamp < p.readyAt) revert TransferNotReady();
        if (block.timestamp > p.expiresAt) revert TransferExpired();

        Launch storage l = launches[token];
        address from = l.creator;
        l.creator = p.to;
        delete pendingCreatorOf[token];
        emit CreatorTransferred(token, from, p.to);
    }

    /// @notice Collect the position's accrued trading fees for a token and split
    /// them among creator, treasury, and the distributor's holder share. Callable
    /// by anyone.
    function collect(address token)
        external
        nonReentrant
        returns (uint256 quoteFees, uint256 tokenFees, uint256 quoteToLp, uint256 tokenToLp)
    {
        Launch memory launch = launches[token];
        if (launch.creator == address(0)) revert UnknownToken();

        // Do not pull fees the distributor could not distribute; they stay in the
        // locked position and the next collect takes them. Returns zeros rather
        // than reverting, so `crank` reports nothing collected and pays no bounty.
        if (launch.distributor != address(0) && !IDistributor(launch.distributor).canAccrue(token)) {
            emit CollectionDeferred(token);
            return (0, 0, 0, 0);
        }

        (quoteFees, tokenFees) = _pullFees(launch);

        cumulativeQuoteFees[token] += quoteFees;

        (quoteToLp, tokenToLp) =
            _compound(token, launch, quoteFees * launch.lpBps / 10_000, tokenFees * launch.lpBps / 10_000);

        _distribute(token, launch, quoteFees, tokenFees, quoteToLp, tokenToLp);
        emit FeesCollected(token, quoteFees, tokenFees);
    }

    /// @notice Adds the liquidity share of the fees back into the locked
    /// position. Only the binding side of the pair is consumed, since liquidity
    /// can only be added in the ratio the current price implies; the caller
    /// returns the rest to the normal split. The add is attempted independently
    /// of the collection, which completes either way.
    function _compound(address token, Launch memory launch, uint256 quoteBudget, uint256 tokenBudget)
        private
        returns (uint256 quoteUsed, uint256 tokenUsed)
    {
        if (quoteBudget == 0 && tokenBudget == 0) return (0, 0);

        Currency quote = launch.poolKey.currency0;
        Currency tok = launch.poolKey.currency1;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(launch.poolKey.toId());
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(launch.poolKey.tickSpacing)),
            TickMath.getSqrtPriceAtTick(launch.tickUpper),
            quoteBudget,
            tokenBudget
        );
        if (liquidity == 0) return (0, 0);

        // Both sides are ERC-20 here, so both need a permit2 allowance.
        // forceApprove handles no-return tokens and those that require an
        // allowance be zeroed before it is raised.
        if (quoteBudget != 0) {
            address q = Currency.unwrap(quote);
            IERC20(q).forceApprove(address(permit2), quoteBudget);
            permit2.approve(q, address(positionManager), uint160(quoteBudget), uint48(block.timestamp));
        }
        if (tokenBudget != 0) {
            IERC20(token).forceApprove(address(permit2), tokenBudget);
            permit2.approve(token, address(positionManager), uint160(tokenBudget), uint48(block.timestamp));
        }

        uint256 quoteBefore = quote.balanceOfSelf();
        uint256 tokenBefore = tok.balanceOfSelf();

        bytes memory actions = abi.encodePacked(uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(launch.tokenId, liquidity, uint128(quoteBudget), uint128(tokenBudget), bytes(""));
        params[1] = abi.encode(quote, tok);

        try positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp) {
            // The quote settles through its own transferFrom and can leave the
            // balance higher than it started, so these saturate at zero. Any
            // surplus stays put: these balances also hold deferred payouts owed
            // for other tokens.
            uint256 quoteAfter = quote.balanceOfSelf();
            uint256 tokenAfter = tok.balanceOfSelf();
            quoteUsed = quoteBefore > quoteAfter ? quoteBefore - quoteAfter : 0;
            tokenUsed = tokenBefore > tokenAfter ? tokenBefore - tokenAfter : 0;
            emit FeesCompounded(token, quoteUsed, tokenUsed, liquidity);
        } catch {
            emit CompoundSkipped(token, quoteBudget, tokenBudget);
        }
    }

    /// @notice Decreases zero liquidity to sweep only accrued fees, measured as the
    /// balance change in each currency.
    function _pullFees(Launch memory launch) private returns (uint256 quoteFees, uint256 tokenFees) {
        Currency quote = launch.poolKey.currency0;
        Currency tok = launch.poolKey.currency1;
        uint256 quoteBefore = quote.balanceOfSelf();
        uint256 tokenBefore = tok.balanceOfSelf();

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(launch.tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(quote, tok, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        quoteFees = quote.balanceOfSelf() - quoteBefore;
        tokenFees = tok.balanceOfSelf() - tokenBefore;
    }

    /// @notice Pays the creator and treasury their quote shares, forwards the holder
    /// share to the distributor, and forwards token fees. Quote transfers that fail
    /// (e.g. a paused stock) are recorded as owed for later retry instead of reverting.
    function _distribute(
        address token,
        Launch memory launch,
        uint256 quoteFees,
        uint256 tokenFees,
        uint256 quoteToLp,
        uint256 tokenToLp
    ) private {
        Currency quote = launch.poolKey.currency0;
        Currency tok = launch.poolKey.currency1;

        // The compounded share is funded entirely out of the creator and holder
        // pool, so the treasury keeps exactly the share it always had and any
        // budget the add could not absorb flows back to creator and holders.
        uint16 payout = launch.creatorBps + launch.holdersBps;
        uint256 quoteCreator;
        uint256 quoteHolders;
        if (payout != 0) {
            uint256 payoutQuote = quoteFees * payout / 10_000 - quoteToLp;
            quoteCreator = payoutQuote * launch.creatorBps / payout;
            quoteHolders = payoutQuote - quoteCreator;
        }
        // With no distributor there is no holder share to route; it goes to
        // the treasury.
        if (launch.distributor == address(0)) quoteHolders = 0;

        uint256 quoteTreasury = quoteFees - quoteCreator - quoteHolders - quoteToLp;
        // The creator's leg is deferred per launch; the treasury's is deferred
        // per recipient, because the treasury is immutable and never moves.
        if (quoteCreator != 0 && !_tryTransfer(quote, launch.creator, quoteCreator)) {
            deferredCreatorQuote[token] += quoteCreator;
            emit CreatorQuoteDeferred(token, quoteCreator);
        }
        if (quoteTreasury != 0) _payQuote(quote, treasury, quoteTreasury);

        uint256 holderDeposit = quoteHolders;
        if (quoteHolders != 0 && !_tryTransfer(quote, launch.distributor, quoteHolders)) {
            deferredHolderQuote[token] += quoteHolders;
            holderDeposit = 0;
            emit HolderQuoteDeferred(token, quoteHolders);
        }

        uint256 tokenLeft = tokenFees - tokenToLp;
        if (tokenLeft != 0) {
            if (launch.distributor != address(0)) tok.transfer(launch.distributor, tokenLeft);
            else tok.transfer(DEAD, tokenLeft);
        }

        if (launch.distributor != address(0) && (holderDeposit != 0 || tokenLeft != 0)) {
            IDistributor(launch.distributor).deposit(token, holderDeposit, tokenLeft);
        }
    }

    /// @notice Sends a quote payout, recording it as owed to the recipient if the
    /// transfer fails.
    function _payQuote(Currency quote, address to, uint256 amount) private {
        if (_tryTransfer(quote, to, amount)) return;
        quoteOwed[Currency.unwrap(quote)][to] += amount;
        emit QuotePayoutDeferred(Currency.unwrap(quote), to, amount);
    }

    /// @notice Attempts an ERC-20 transfer without reverting, tolerating both
    /// boolean-returning and no-return tokens; returns whether it succeeded.
    function _tryTransfer(Currency currency, address to, uint256 amount) private returns (bool) {
        address quoteToken = Currency.unwrap(currency);
        if (quoteToken.code.length == 0) return false;
        (bool ok, bytes memory ret) = quoteToken.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return true;
        if (ret.length < 32) return false;
        return abi.decode(ret, (uint256)) != 0;
    }

    /// @notice Re-send a previously deferred quote payout to its recipient. Only
    /// the treasury's payouts are deferred by recipient, so that is the only
    /// address this can be called with to any effect; see `quoteOwed`.
    function retryQuotePayout(address quoteToken, address recipient) external nonReentrant {
        uint256 amount = quoteOwed[quoteToken][recipient];
        if (amount == 0) revert NothingOwed();
        quoteOwed[quoteToken][recipient] = 0;
        Currency.wrap(quoteToken).transfer(recipient, amount);
        emit QuotePayoutReleased(quoteToken, recipient, amount);
    }

    /// @notice Re-send a previously deferred creator payout to the launch's
    /// creator.
    /// @dev The recipient is read now, not when the payout was deferred, so a
    /// share the quote refused before a handover is released to whoever holds the
    /// launch today. A revert leaves the amount recorded and the locker still
    /// holding it, so the release is deferred rather than lost.
    function retryCreatorQuote(address token) external nonReentrant {
        Launch memory launch = launches[token];
        uint256 amount = deferredCreatorQuote[token];
        if (amount == 0) revert NothingOwed();
        deferredCreatorQuote[token] = 0;
        launch.poolKey.currency0.transfer(launch.creator, amount);
        emit CreatorQuoteReleased(token, launch.creator, amount);
    }

    /// @notice Re-send a previously deferred holder quote share to the distributor.
    /// @dev Carries the same `canAccrue` guard as `collect`, since this is the
    /// only other path that calls `deposit`. Reverting leaves the amount recorded
    /// and the locker still holding it.
    function retryHolderQuote(address token) external nonReentrant {
        Launch memory launch = launches[token];
        uint256 amount = deferredHolderQuote[token];
        if (amount == 0) revert NothingOwed();
        if (!IDistributor(launch.distributor).canAccrue(token)) revert AccrualDeferred();
        deferredHolderQuote[token] = 0;
        launch.poolKey.currency0.transfer(launch.distributor, amount);
        IDistributor(launch.distributor).deposit(token, amount, 0);
        emit HolderQuoteReleased(token, amount);
    }
}
