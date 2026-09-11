// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {IDistributor} from "./interfaces/IDistributor.sol";

interface ILockerCollect {
    function collect(address token)
        external
        returns (uint256 quoteFees, uint256 tokenFees, uint256 quoteToLp, uint256 tokenToLp);
}

/**
 * @title ArchrDistributor
 * @notice Holds and distributes the holder share of each token's trading fees.
 * Per its reward configuration it either pays WETH rewards to holders, or spends
 * WETH buying the token back and then reflects or burns it. Holder shares track
 * balances through the token's checkpoint callback. `crank`, `process` and
 * `claim` are open to any caller, the first two paying the caller a bounty, so
 * collection and distribution never depend on a privileged keeper.
 */
contract ArchrDistributor is IDistributor, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 private constant MAG = 2 ** 128;

    uint16 public constant BOUNTY_BPS = 100;

    uint16 public constant PUSH_SKIM_BPS = 100;

    uint16 public constant PROCESS_SKIM_BPS = 100;

    uint256 private constant MIN_DISTRIBUTION_SHARES = 1e24;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    address public immutable launchpad;
    address public immutable deployer;
    address public immutable locker;
    Currency public immutable weth;

    /// Ceiling on the sqrt-price move one buyback may cause, in bps; 100 is a
    /// ~2% move in price.
    uint16 public immutable maxSqrtMoveBps;

    /// Rate at which buyback allowance accrues, in sqrt bps per block, up to
    /// `maxSqrtMoveBps`. Capacity scales with elapsed time rather than with the
    /// number of calls, so it does not fall behind when the pool is busy.
    uint16 public immutable sqrtMoveBpsPerBlock;

    struct Pool {
        bool registered;
        RewardConfig config;
        PoolKey poolKey;
        uint256 totalShares;
        uint256 magWethPerShare;
        uint256 magTokenPerShare;
        uint256 pendingWeth;
        uint256 pendingToken;

        uint256 pendingTokenReflect;
        uint256 wethReserved;
        uint256 tokenReserved;
        /// Bucket anchor: the block at which this pool's buyback allowance was
        /// last zero. Allowance is `(block.number - anchor) * sqrtMoveBpsPerBlock`,
        /// capped at `maxSqrtMoveBps`. Zero means never bought back, which reads
        /// as a full bucket.
        uint256 lastBuybackBlock;

        uint256 totalWethReflected;
        uint256 totalWethBuyback;
        uint256 totalTokenBought;
        uint256 totalTokenReflected;
        uint256 totalTokenBurned;
    }

    /// @notice What one `process` call actually moved, and the skim each side
    /// earned. Carried by reference through the process legs.
    struct Moved {
        uint256 wethOut;
        uint256 tokenReflected;
        uint256 tokenBurned;
        uint256 wethSkim;
        uint256 tokenSkim;
    }

    mapping(address token => Pool) internal pools;
    mapping(address token => mapping(address holder => uint256)) public sharesOf;
    mapping(address token => mapping(address holder => int256)) private wethCorrection;
    mapping(address token => mapping(address holder => int256)) private tokenCorrection;
    mapping(address token => mapping(address holder => uint256)) public wethWithdrawn;
    mapping(address token => mapping(address holder => uint256)) public tokenWithdrawn;
    mapping(address holder => bool) public excludedFromRewards;

    /// True once a token has registered. Exclusions are only safe before that
    /// point — see `excludeFromRewards`.
    bool private wiringClosed;

    event Registered(address indexed token);
    event ExcludedFromRewards(address indexed account);
    event Processed(address indexed token, uint256 wethOut, uint256 tokenReflected, uint256 tokenBurned);
    event Claimed(address indexed token, address indexed holder, uint256 wethAmount, uint256 tokenAmount);
    event Distributed(
        address indexed token, address indexed keeper, uint256 holdersPaid, uint256 wethSkim, uint256 tokenSkim
    );

    error OnlyLauncher();
    error OnlyDeployer();
    error WiringClosed();
    error OnlyLocker();
    error OnlyPoolManager();
    error AlreadyRegistered();
    error NotRegistered();
    error BadConfig();
    error UnexpectedNativeSender();
    error BadBuybackLimits();

    constructor(
        IPoolManager _poolManager,
        address _launchpad,
        address _locker,
        Currency _weth,
        uint16 _maxSqrtMoveBps,
        uint16 _sqrtMoveBpsPerBlock
    ) {
        if (_sqrtMoveBpsPerBlock == 0 || _maxSqrtMoveBps == 0) revert BadBuybackLimits();
        if (_maxSqrtMoveBps >= 10_000) revert BadBuybackLimits();
        if (_sqrtMoveBpsPerBlock > _maxSqrtMoveBps) revert BadBuybackLimits();

        poolManager = _poolManager;
        launchpad = _launchpad;
        deployer = msg.sender;
        locker = _locker;
        weth = _weth;
        maxSqrtMoveBps = _maxSqrtMoveBps;
        sqrtMoveBpsPerBlock = _sqrtMoveBpsPerBlock;

        excludedFromRewards[_launchpad] = true;
        excludedFromRewards[_locker] = true;
        excludedFromRewards[address(this)] = true;
        excludedFromRewards[address(_poolManager)] = true;
        excludedFromRewards[DEAD] = true;
    }

    receive() external payable {
        if (msg.sender != Currency.unwrap(weth)) revert UnexpectedNativeSender();
    }

    /// @notice Register a launched token's pool and reward split. Callable once,
    /// only by the launchpad.
    function register(address token, PoolKey calldata poolKey, RewardConfig calldata config) external {
        if (msg.sender != launchpad) revert OnlyLauncher();
        // From here a token is registered, so `checkpoint` can give an address
        // shares and excluding one would strand them in `totalShares`. Wiring
        // is over.
        if (!wiringClosed) wiringClosed = true;
        if (pools[token].registered) revert AlreadyRegistered();
        if (uint256(config.ethRewardsBps) + config.buybackReflectBps + config.buybackBurnBps != 10_000) {
            revert BadConfig();
        }
        if (config.tokenReflectBps > 10_000) revert BadConfig();

        if (config.ethRewardsBps != 0 && config.ethRewardsBps != 10_000) revert BadConfig();

        Pool storage p = pools[token];
        p.registered = true;
        p.config = config;
        p.poolKey = poolKey;
        emit Registered(token);
    }

    /// @notice Exclude an address from reward shares, so its balance is left out
    /// of `totalShares` and accrues nothing. Deployer only, and only until the
    /// first token registers — exclusion is sound only while the address holds no
    /// shares, and shares exist only for a registered token. One-way.
    function excludeFromRewards(address account) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (wiringClosed) revert WiringClosed();
        excludedFromRewards[account] = true;
        emit ExcludedFromRewards(account);
    }

    /// @notice Record the holder share of collected WETH and token fees as pending.
    /// Callable only by the locker.
    function deposit(address token, uint256 wethAmount, uint256 tokenAmount) external {
        if (msg.sender != locker) revert OnlyLocker();
        if (!pools[token].registered) revert NotRegistered();
        pools[token].pendingWeth += wethAmount;
        pools[token].pendingToken += tokenAmount;
    }

    /// @notice Whether a deposit made now could ever be distributed. False only
    /// when the config routes value through a per-share accumulator and there are
    /// too few shares to divide by; a burn-only pool always accrues.
    function canAccrue(address token) external view returns (bool) {
        Pool storage p = pools[token];
        if (!p.registered) return true;
        if (p.totalShares >= MIN_DISTRIBUTION_SHARES) return true;
        return p.config.ethRewardsBps == 0 && p.config.buybackReflectBps == 0 && p.config.tokenReflectBps == 0;
    }

    /// @notice Token transfer callback that resyncs both parties' reward shares.
    function checkpoint(address from, address to) external {
        address token = msg.sender;
        if (!pools[token].registered) return;
        if (from != address(0)) _syncShare(token, from);
        if (to != address(0)) _syncShare(token, to);
    }

    /// @notice Realigns a holder's share to their current balance, carrying the
    /// accrual correction so already-distributed rewards are unaffected.
    function _syncShare(address token, address holder) private {
        if (excludedFromRewards[holder]) return;
        Pool storage p = pools[token];
        uint256 old = sharesOf[token][holder];
        uint256 bal = IERC20(token).balanceOf(holder);
        if (bal == old) return;

        if (bal > old) {
            uint256 inc = bal - old;
            wethCorrection[token][holder] -= (p.magWethPerShare * inc).toInt256();
            tokenCorrection[token][holder] -= (p.magTokenPerShare * inc).toInt256();
            p.totalShares += inc;
        } else {
            uint256 dec = old - bal;
            wethCorrection[token][holder] += (p.magWethPerShare * dec).toInt256();
            tokenCorrection[token][holder] += (p.magTokenPerShare * dec).toInt256();
            p.totalShares -= dec;
        }
        sharesOf[token][holder] = bal;
    }

    /// @notice Keeper entry point: collects fees from the locker and pays the caller
    /// a bounty on what the collection actually moved, in kind on both sides.
    /// Processing is a separate job — see `process`.
    function crank(address token) external nonReentrant returns (uint256 wethBounty, uint256 tokenBounty) {
        Pool storage p = pools[token];
        if (!p.registered) revert NotRegistered();

        uint256 wethBefore = p.pendingWeth;
        uint256 tokenBefore = p.pendingToken;
        ILockerCollect(locker).collect(token);

        uint256 wethCollected = p.pendingWeth - wethBefore;
        uint256 tokenCollected = p.pendingToken - tokenBefore;

        // Both sides are paid: the locker forwards token fees regardless of the
        // holder share, so a token-only collection must fund itself.
        wethBounty = wethCollected * BOUNTY_BPS / 10_000;
        if (wethBounty > 0) {
            p.pendingWeth -= wethBounty;
            weth.transfer(msg.sender, wethBounty);
        }
        tokenBounty = tokenCollected * BOUNTY_BPS / 10_000;
        if (tokenBounty > 0) {
            p.pendingToken -= tokenBounty;
            IERC20(token).safeTransfer(msg.sender, tokenBounty);
        }
    }

    /// @notice Process already-pending fees, paying the caller a skim of whatever
    /// the call actually moved. Returns what was paid, so a keeper can simulate the
    /// call and price it exactly.
    function process(address token) external nonReentrant returns (uint256 wethSkim, uint256 tokenSkim) {
        if (!pools[token].registered) revert NotRegistered();
        return _process(token);
    }

    /// @notice Applies the reward config to pending fees: pays WETH rewards and/or
    /// runs a rate-limited buyback, and reflects or burns token fees.
    /// @dev Each skim is withheld on the way out and charged only on what moved.
    /// Value that re-queues carries its withholding back with it, so a pot cannot
    /// be skimmed twice for one job.
    function _process(address token) private returns (uint256, uint256) {
        Pool storage p = pools[token];
        Moved memory m;

        uint256 wethIn = p.pendingWeth;
        uint256 tokenIn = p.pendingToken;
        uint256 reflectIn = p.pendingTokenReflect;
        p.pendingWeth = 0;
        p.pendingToken = 0;
        p.pendingTokenReflect = 0;

        if (wethIn > 0) _processWeth(token, wethIn, m);
        if (tokenIn > 0) {
            uint256 reflectAmt = tokenIn * p.config.tokenReflectBps / 10_000;
            _reflect(token, reflectAmt, m);
            _burnSkimmed(token, tokenIn - reflectAmt, m);
        }
        if (reflectIn > 0) _reflect(token, reflectIn, m);

        p.totalWethReflected += m.wethOut;
        p.totalTokenReflected += m.tokenReflected;
        p.totalTokenBurned += m.tokenBurned;

        if (m.wethSkim > 0) weth.transfer(msg.sender, m.wethSkim);
        if (m.tokenSkim > 0) IERC20(token).safeTransfer(msg.sender, m.tokenSkim);

        emit Processed(token, m.wethOut, m.tokenReflected, m.tokenBurned);
        return (m.wethSkim, m.tokenSkim);
    }

    /// @notice Splits pending WETH into the direct reward share and the buyback
    /// budget, withholding each one's skim before it is spent.
    function _processWeth(address token, uint256 wethIn, Moved memory m) private {
        Pool storage p = pools[token];
        uint256 ethAmount = wethIn * p.config.ethRewardsBps / 10_000;
        uint256 buybackBudget = wethIn - ethAmount;

        if (ethAmount > 0) {
            uint256 withheld = ethAmount * PROCESS_SKIM_BPS / 10_000;
            uint256 out = _distributeWeth(token, ethAmount - withheld);
            if (out == 0) {
                p.pendingWeth += withheld;
            } else {
                m.wethOut += out;
                m.wethSkim += withheld;
            }
        }

        if (buybackBudget == 0) return;

        // Nothing has accrued yet this block; re-queue rather than swap for zero.
        uint256 allowanceBps = _buybackAllowanceBps(p);
        if (allowanceBps == 0) {
            p.pendingWeth += buybackBudget;
            return;
        }

        // Swapped WETH is gone by the time the skim is owed, so hold the skim
        // back up front and return whatever the swap didn't use.
        uint256 held = buybackBudget * PROCESS_SKIM_BPS / 10_000;
        uint256 spent = _processBuyback(token, buybackBudget - held, m, uint16(allowanceBps));
        uint256 skim = spent * PROCESS_SKIM_BPS / 10_000;
        m.wethSkim += skim;
        p.pendingWeth += held - skim;
    }

    /// @notice The block this pool's allowance is measured from. An anchor older
    /// than one full refill normalises to full, so credit past the cap is
    /// forfeited rather than carried.
    function _bucketAnchor(Pool storage p) private view returns (uint256) {
        // Rounded up so a ceiling that is not a multiple of the rate is still
        // reachable; the cap in `_buybackAllowanceBps` clamps the extra.
        uint256 rate = sqrtMoveBpsPerBlock;
        uint256 refillBlocks = (uint256(maxSqrtMoveBps) + rate - 1) / rate;
        uint256 fullSince = block.number > refillBlocks ? block.number - refillBlocks : 0;
        uint256 last = p.lastBuybackBlock;
        return last < fullSince ? fullSince : last;
    }

    /// @notice Buyback allowance accrued for this pool, in sqrt bps.
    function _buybackAllowanceBps(Pool storage p) private view returns (uint256) {
        uint256 allowance = (block.number - _bucketAnchor(p)) * sqrtMoveBpsPerBlock;
        return allowance > maxSqrtMoveBps ? maxSqrtMoveBps : allowance;
    }

    /// @notice Charges the bucket for the price move a buyback caused, by
    /// advancing the anchor. Charging realised impact means a swap that moved
    /// nothing costs nothing.
    /// @dev Rounds up, so a move below one block's accrual still costs a block.
    function _advanceBuybackClock(Pool storage p, uint256 consumedBps) private {
        if (consumedBps == 0) return;
        uint256 rate = sqrtMoveBpsPerBlock;
        uint256 advanced = _bucketAnchor(p) + (consumedBps + rate - 1) / rate;
        // `consumedBps` is bounded by the allowance the elapsed blocks bought, so
        // this cannot pass the present; clamped so it can never starve the pool.
        p.lastBuybackBlock = advanced > block.number ? block.number : advanced;
    }

    /// @notice Spends the WETH budget buying the token back, then splits what was
    /// bought between reflection and burn per the config.
    function _processBuyback(address token, uint256 wethBudget, Moved memory m, uint16 allowanceBps)
        private
        returns (uint256 spent)
    {
        Pool storage p = pools[token];
        uint256 bought;
        uint256 consumedBps;
        (spent, bought, consumedBps) = _buyback(token, wethBudget, allowanceBps);
        _advanceBuybackClock(p, consumedBps);
        if (wethBudget - spent > 0) p.pendingWeth += wethBudget - spent;

        p.totalWethBuyback += spent;
        p.totalTokenBought += bought;

        uint256 denom = uint256(p.config.buybackReflectBps) + p.config.buybackBurnBps;
        uint256 reflectAmt = bought * p.config.buybackReflectBps / denom;
        _reflect(token, reflectAmt, m);
        _burnSkimmed(token, bought - reflectAmt, m);
    }

    /// @notice Reflects `amount` less the process skim. A re-queue moves nothing,
    /// so it pays nothing and the withholding re-queues with it.
    function _reflect(address token, uint256 amount, Moved memory m) private {
        if (amount == 0) return;
        uint256 withheld = amount * PROCESS_SKIM_BPS / 10_000;
        uint256 reflected = _distributeToken(token, amount - withheld);
        if (reflected == 0) {
            pools[token].pendingTokenReflect += withheld;
        } else {
            m.tokenReflected += reflected;
            m.tokenSkim += withheld;
        }
    }

    /// @notice Burns `amount` less the process skim. A burn always moves, so the
    /// skim is always earned.
    function _burnSkimmed(address token, uint256 amount, Moved memory m) private {
        if (amount == 0) return;
        uint256 skim = amount * PROCESS_SKIM_BPS / 10_000;
        _burn(token, amount - skim);
        m.tokenBurned += amount - skim;
        m.tokenSkim += skim;
    }

    /// @notice Adds WETH to the per-share accumulator, or holds it pending while
    /// too few shares exist to distribute against.
    function _distributeWeth(address token, uint256 amount) private returns (uint256) {
        Pool storage p = pools[token];
        if (p.totalShares < MIN_DISTRIBUTION_SHARES) {
            p.pendingWeth += amount;
            return 0;
        }
        p.magWethPerShare += FullMath.mulDiv(amount, MAG, p.totalShares);
        p.wethReserved += amount;
        return amount;
    }

    /// @notice Adds token to the per-share accumulator, or holds it pending while
    /// too few shares exist to distribute against.
    function _distributeToken(address token, uint256 amount) private returns (uint256) {
        Pool storage p = pools[token];
        if (p.totalShares < MIN_DISTRIBUTION_SHARES) {
            p.pendingTokenReflect += amount;
            return 0;
        }
        p.magTokenPerShare += FullMath.mulDiv(amount, MAG, p.totalShares);
        p.tokenReserved += amount;
        return amount;
    }

    function _burn(address token, uint256 amount) private {
        IERC20(token).safeTransfer(DEAD, amount);
    }

    /// @notice Claim the caller's accrued WETH and token rewards for a token.
    function claim(address token) external nonReentrant {
        _claim(token, msg.sender);
    }

    /// @notice Claim rewards on behalf of a holder; proceeds go to that holder.
    function claimFor(address token, address holder) external nonReentrant {
        _claim(token, holder);
    }

    /// @notice Push rewards to many holders at once. The caller keeps a small skim
    /// of each paid amount as compensation for triggering the distribution.
    function claimForMany(address token, address[] calldata holders) external nonReentrant {
        Pool storage p = pools[token];
        if (!p.registered) revert NotRegistered();

        uint256 wethSkimTotal;
        uint256 tokenSkimTotal;
        uint256 paid;

        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            uint256 wethAmount = withdrawableWeth(token, holder);
            uint256 tokenAmount = withdrawableToken(token, holder);
            if (wethAmount == 0 && tokenAmount == 0) continue;

            if (wethAmount > 0) {
                uint256 skim = wethAmount * PUSH_SKIM_BPS / 10_000;
                wethWithdrawn[token][holder] += wethAmount;
                p.wethReserved -= wethAmount;
                wethSkimTotal += skim;
                weth.transfer(holder, wethAmount - skim);
            }
            if (tokenAmount > 0) {
                uint256 skim = tokenAmount * PUSH_SKIM_BPS / 10_000;
                tokenWithdrawn[token][holder] += tokenAmount;
                p.tokenReserved -= tokenAmount;
                tokenSkimTotal += skim;

                IERC20(token).safeTransfer(holder, tokenAmount - skim);
            }
            emit Claimed(token, holder, wethAmount, tokenAmount);
            paid++;
        }

        if (wethSkimTotal > 0) weth.transfer(msg.sender, wethSkimTotal);
        if (tokenSkimTotal > 0) IERC20(token).safeTransfer(msg.sender, tokenSkimTotal);
        emit Distributed(token, msg.sender, paid, wethSkimTotal, tokenSkimTotal);
    }

    function _claim(address token, address holder) private {
        Pool storage p = pools[token];
        uint256 wethAmount = withdrawableWeth(token, holder);
        uint256 tokenAmount = withdrawableToken(token, holder);

        if (wethAmount > 0) {
            wethWithdrawn[token][holder] += wethAmount;
            p.wethReserved -= wethAmount;
            weth.transfer(holder, wethAmount);
        }
        if (tokenAmount > 0) {
            tokenWithdrawn[token][holder] += tokenAmount;
            p.tokenReserved -= tokenAmount;

            IERC20(token).safeTransfer(holder, tokenAmount);
        }
        if (wethAmount > 0 || tokenAmount > 0) emit Claimed(token, holder, wethAmount, tokenAmount);
    }

    /// @notice WETH rewards a holder can currently claim.
    function withdrawableWeth(address token, address holder) public view returns (uint256) {
        int256 acc = (pools[token].magWethPerShare * sharesOf[token][holder]).toInt256() + wethCorrection[token][holder];
        return uint256(acc) / MAG - wethWithdrawn[token][holder];
    }

    /// @notice Token rewards a holder can currently claim.
    function withdrawableToken(address token, address holder) public view returns (uint256) {
        int256 acc = (pools[token].magTokenPerShare * sharesOf[token][holder]).toInt256() + tokenCorrection[token][holder];
        return uint256(acc) / MAG - tokenWithdrawn[token][holder];
    }

    function pendingWethOf(address token) external view returns (uint256) {
        return pools[token].pendingWeth;
    }

    function pendingTokenOf(address token) external view returns (uint256) {
        return pools[token].pendingToken + pools[token].pendingTokenReflect;
    }

    /// @notice Bucket anchor for this token's buybacks, for diagnostics. A keeper
    /// deciding whether to call should read `buybackAllowanceBpsOf` instead.
    function lastBuybackBlockOf(address token) external view returns (uint256) {
        return pools[token].lastBuybackBlock;
    }

    /// @notice Buyback allowance currently accrued for this token, in sqrt bps.
    /// Zero means the budget could only re-queue, so a keeper can skip the call.
    function buybackAllowanceBpsOf(address token) external view returns (uint256) {
        return _buybackAllowanceBps(pools[token]);
    }

    function wethLiabilityOf(address token) external view returns (uint256) {
        return pools[token].pendingWeth + pools[token].wethReserved;
    }

    function tokenLiabilityOf(address token) external view returns (uint256) {
        return pools[token].pendingToken + pools[token].pendingTokenReflect + pools[token].tokenReserved;
    }

    function poolInfo(address token)
        external
        view
        returns (bool registered, RewardConfig memory config, PoolKey memory poolKey)
    {
        Pool storage p = pools[token];
        return (p.registered, p.config, p.poolKey);
    }

    function lifetimeStats(address token)
        external
        view
        returns (
            uint256 wethReflected,
            uint256 wethBuyback,
            uint256 tokenBought,
            uint256 tokenReflected,
            uint256 tokenBurned
        )
    {
        Pool storage p = pools[token];
        return (p.totalWethReflected, p.totalWethBuyback, p.totalTokenBought, p.totalTokenReflected, p.totalTokenBurned);
    }

    /// @notice Swaps WETH for the token, capping price impact at the allowance
    /// the bucket has accrued, and reporting back how much of it was used.
    function _buyback(address token, uint256 wethIn, uint16 allowanceBps)
        private
        returns (uint256 spent, uint256 tokenOut, uint256 consumedBps)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pools[token].poolKey.toId());

        // Floor the swap price at the accrued allowance below the current sqrt price.
        uint160 limit = uint160(sqrtPriceX96 - uint256(sqrtPriceX96) * allowanceBps / 10_000);

        uint160 minLimit = TickMath.MIN_SQRT_PRICE + 1;
        if (limit < minLimit) limit = minLimit;

        // When the clamp leaves no room below the current price, skip the swap
        // and return zeros so the caller re-queues the budget.
        if (limit >= sqrtPriceX96) return (0, 0, 0);

        bytes memory res = poolManager.unlock(abi.encode(token, wethIn, limit));
        (spent, tokenOut, consumedBps) = abi.decode(res, (uint256, uint256, uint256));
    }

    /// @notice Pool-manager callback executing the buyback swap and settling it in
    /// native ETH unwrapped from WETH. Only the pool manager may call.
    /// @dev The realised sqrt move is measured inside the lock, either side of the
    /// swap, where no other trade can interleave and the difference is therefore
    /// this swap's own impact and nothing else.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        (address token, uint256 wethIn, uint160 limit) = abi.decode(data, (address, uint256, uint160));
        PoolKey memory poolKey = pools[token].poolKey;
        PoolId id = poolKey.toId();

        (uint160 sqrtBefore,,,) = poolManager.getSlot0(id);
        BalanceDelta delta = poolManager.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(wethIn), sqrtPriceLimitX96: limit}),
            ""
        );
        (uint160 sqrtAfter,,,) = poolManager.getSlot0(id);

        // zeroForOne moves the sqrt price down; guarded so a reading that did not
        // fall reports zero rather than underflowing.
        uint256 consumedBps =
            sqrtBefore > sqrtAfter ? uint256(sqrtBefore - sqrtAfter) * 10_000 / sqrtBefore : 0;

        uint256 spent = uint256(uint128(-delta.amount0()));
        uint256 out = uint256(uint128(delta.amount1()));

        IWETH9(Currency.unwrap(weth)).withdraw(spent);
        poolManager.sync(CurrencyLibrary.ADDRESS_ZERO);
        poolManager.settle{value: spent}();
        poolManager.take(poolKey.currency1, address(this), out);

        return abi.encode(spent, out, consumedBps);
    }
}
