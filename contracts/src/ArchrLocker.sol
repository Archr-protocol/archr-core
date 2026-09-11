// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

import {ILockerFeeMetric} from "./interfaces/ILockerFeeMetric.sol";
import {IDistributor} from "./interfaces/IDistributor.sol";

/**
 * @title ArchrLocker
 * @notice Permanently holds the launch liquidity position for each token,
 * collects its Uniswap v4 trading fees on demand, and splits them between the
 * creator, the protocol treasury, and the holder/burn distributor share. ETH
 * fees are wrapped to WETH before being paid out.
 */
contract ArchrLocker is ILockerFeeMetric, ReentrancyGuard {
    using CurrencyLibrary for Currency;
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
    IWETH9 public immutable weth;
    IPoolManager public immutable poolManager;
    address public immutable treasury;
    address public immutable deployer;
    address public launchpad;

    mapping(address token => Launch) public launches;
    mapping(address token => uint256) public override cumulativeQuoteFees;

    event LaunchLocked(address indexed token, address indexed creator, uint256 tokenId);
    event FeesCollected(address indexed token, uint256 quoteFees, uint256 tokenFees);
    /// `quoteAdded`/`tokenAdded` are a lower bound: a sweep that returns more
    /// than the add consumed saturates them to zero. See _compound.
    event FeesCompounded(address indexed token, uint256 quoteAdded, uint256 tokenAdded, uint128 liquidity);
    /// Emitted when the compounding add did not go through; the liquidity share
    /// falls back into the normal split and the collection completes.
    event CompoundSkipped(address indexed token, uint256 quoteBudget, uint256 tokenBudget);
    /// Emitted when a collect declined to pull because the distributor has too
    /// few shares to divide by. The fees stay in the locked position and the
    /// next collect takes them.
    event CollectionDeferred(address indexed token);

    error AlreadyInitialized();
    error OnlyDeployer();
    error OnlyLaunchpad();
    error UnknownToken();
    error UnexpectedNativeSender();
    error ZeroTreasury();

    constructor(IPositionManager _positionManager, IPermit2 _permit2, address _treasury, IWETH9 _weth) {
        if (_treasury == address(0)) revert ZeroTreasury();
        positionManager = _positionManager;
        permit2 = _permit2;
        treasury = _treasury;
        weth = _weth;
        deployer = msg.sender;
        poolManager = IPoolManager(address(_positionManager.poolManager()));
    }

    /// @notice Native ETH arrives from the pool manager when fees are taken, and
    /// back from the position manager when a compounding add sweeps its unspent
    /// value.
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != address(positionManager)) {
            revert UnexpectedNativeSender();
        }
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

    /// @notice Collect the position's accrued trading fees for a token, compound
    /// the liquidity share back into the locked position, and split the rest among
    /// creator, treasury, and the distributor's holder share. Callable by anyone.
    function collect(address token)
        external
        nonReentrant
        returns (uint256 quoteFees, uint256 tokenFees, uint256 quoteToLp, uint256 tokenToLp)
    {
        Launch memory launch = launches[token];
        if (launch.creator == address(0)) revert UnknownToken();

        // Do not pull fees the distributor could not distribute; they stay in the
        // locked position and the next collect takes them. Creator and treasury
        // are deferred with the holder share rather than paid out of a collection
        // that would strand it. Returns zeros rather than reverting, so `crank`
        // reports nothing collected and pays no bounty.
        if (launch.distributor != address(0) && !IDistributor(launch.distributor).canAccrue(token)) {
            emit CollectionDeferred(token);
            return (0, 0, 0, 0);
        }

        (quoteFees, tokenFees) = _pullFees(launch);

        // The graduation metric counts everything the pool earned, including the
        // part that goes straight back into liquidity.
        cumulativeQuoteFees[token] += quoteFees;

        // Compound before wrapping: currency0 is native ETH, so the position
        // manager must be paid in ETH, not WETH.
        (quoteToLp, tokenToLp) =
            _compound(token, launch, quoteFees * launch.lpBps / 10_000, tokenFees * launch.lpBps / 10_000);

        // The compound's SWEEP returns the position manager's whole native
        // balance, which can exceed this call's unspent value, so the split pays
        // out the balance held rather than the arithmetic remainder.
        uint256 quoteLeft = address(this).balance;
        if (quoteLeft != 0) weth.deposit{value: quoteLeft}();

        _distribute(token, launch, quoteLeft + quoteToLp, tokenFees, quoteToLp, tokenToLp);
        emit FeesCollected(token, quoteFees, tokenFees);
    }

    /// @notice Adds the liquidity share of the fees back into the locked position.
    /// Fees arrive in the ratio of trade flow, but liquidity must be added in the
    /// ratio the current price implies, so only the binding side is consumed; the
    /// unused remainder is returned by the caller to the normal split.
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

        if (tokenBudget != 0) {
            IERC20(token).approve(address(permit2), tokenBudget);
            permit2.approve(token, address(positionManager), uint160(tokenBudget), uint48(block.timestamp));
        }

        uint256 quoteBefore = quote.balanceOfSelf();
        uint256 tokenBefore = tok.balanceOfSelf();

        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(launch.tokenId, liquidity, uint128(quoteBudget), uint128(tokenBudget), bytes(""));
        params[1] = abi.encode(quote, tok);
        params[2] = abi.encode(quote, address(this));

        try positionManager.modifyLiquidities{value: quoteBudget}(abi.encode(actions, params), block.timestamp) {
            // SWEEP returns the position manager's entire native balance, so the
            // balance can come back higher than it went out. Saturate rather than
            // panic in the success arm, where the catch below would not reach it.
            // These are therefore a lower bound on what compounded; the split uses
            // the balance, not these.
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

    /// @notice Pays the creator and distributor their WETH shares, sends the
    /// remainder to the treasury, forwards token fees, and notifies the
    /// distributor. The compounded share is funded out of the creator and holder
    /// pool, so the treasury keeps the share it always had. `quoteSplit` is the
    /// WETH now held plus what the compound consumed.
    function _distribute(
        address token,
        Launch memory launch,
        uint256 quoteSplit,
        uint256 tokenFees,
        uint256 quoteToLp,
        uint256 tokenToLp
    ) private {
        Currency wethC = Currency.wrap(address(weth));
        Currency tok = launch.poolKey.currency1;

        uint16 payout = launch.creatorBps + launch.holdersBps;
        uint256 quoteCreator;
        uint256 quoteHolders;
        if (payout != 0) {
            uint256 payoutQuote = quoteSplit * payout / 10_000 - quoteToLp;
            quoteCreator = payoutQuote * launch.creatorBps / payout;
            quoteHolders = payoutQuote - quoteCreator;
        }

        // With no distributor there is no holder share to route; it goes to
        // the treasury with the remainder.
        if (launch.distributor == address(0)) quoteHolders = 0;

        if (quoteCreator != 0) wethC.transfer(launch.creator, quoteCreator);
        if (quoteHolders != 0) wethC.transfer(launch.distributor, quoteHolders);
        wethC.transfer(treasury, quoteSplit - quoteCreator - quoteHolders - quoteToLp);

        uint256 tokenLeft = tokenFees - tokenToLp;
        if (tokenLeft != 0) {
            if (launch.distributor != address(0)) tok.transfer(launch.distributor, tokenLeft);
            else tok.transfer(DEAD, tokenLeft);
        }

        if (launch.distributor != address(0) && (quoteHolders != 0 || tokenLeft != 0)) {
            IDistributor(launch.distributor).deposit(token, quoteHolders, tokenLeft);
        }
    }
}
