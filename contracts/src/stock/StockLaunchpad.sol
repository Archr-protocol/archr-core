// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ArchrToken} from "../ArchrToken.sol";
import {StockLocker} from "./StockLocker.sol";
import {IDistributor} from "../interfaces/IDistributor.sol";

interface IStock {
    function uid() external view returns (bytes32);
}

interface IStockFactory {
    function tokenAddress(bytes32 uid) external view returns (address);
}

/**
 * @title StockLaunchpad
 * @notice Deploys a fixed-supply token, creates and seeds a permanently locked
 * Uniswap v4 pool quoted in a factory-verified stock token, and performs an
 * atomic first buy paid in that quote token. `launch` opens a token on the 1%
 * creator tier with an optional burn-dial share; `launchReflection` opens a token
 * on the reflection tiers. A flat creation fee in ETH is forwarded to the treasury.
 */
contract StockLaunchpad is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    int24 public constant TICK_SPACING = 200;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// Wider than the native cell's on purpose. The quote is a share of an
    /// arbitrary stock, so a given tick means a different valuation for every
    /// quote and these bounds constrain which quotes are usable rather than how a
    /// token may be valued. Narrowing them narrows which quotes can launch.
    int24 public constant MIN_INITIAL_TICK = 40_000;
    int24 public constant MAX_INITIAL_TICK = 280_000;

    uint24 public constant CREATOR_TIER_FEE = 10_000;
    uint16 public constant CREATOR_TIER_SPLIT_BPS = 7000;

    uint16 public constant PROTOCOL_BPS = 1000;
    uint16 public constant MIN_HOLDERS_BPS = 5000;
    uint16 public constant MAX_HOLDERS_BPS = 9000;

    uint24 public constant MIN_REFLECTION_FEE = 30_000;
    uint24 public constant MAX_REFLECTION_FEE = 100_000;

    /// Ceiling on the share of every trade compounded back into the locked
    /// position, in fee units so it is the same 0.20% of volume on every tier.
    /// Funded out of the creator and holder pool. What actually compounds is
    /// usually less; the unused budget falls through to the normal split.
    uint24 public constant TARGET_LP_RATE = 2_000;

    uint16 public constant MAX_WALLET_BPS = 200;
    uint32 public constant LIMITS_WINDOW_BLOCKS = 3666;

    uint256 public constant CREATION_FEE = 0.002 ether;

    /// Minimum first buy, as a share of supply. Stated against supply rather
    /// than against the quote because the quote's price is unknown on chain. 10
    /// bps of supply is exactly `MIN_DISTRIBUTION_SHARES`, so a launch opens able
    /// to distribute. The absolute routability floor belongs in the UI.
    uint16 public constant MIN_FIRST_BUY_SUPPLY_BPS = 10;

    enum Preset {
        Classic,
        EthPrinter,
        Deflationary,
        Balanced
    }

    IPoolManager public immutable poolManager;
    StockLocker public immutable locker;
    IHooks public immutable gate;
    IStockFactory public immutable stockFactory;
    address public immutable deployer;

    IDistributor public distributor;

    struct LaunchParams {
        string name;
        string symbol;
        bytes32 salt;
    }

    struct TokenMeta {
        string logo;
        string description;
        string website;
        string twitter;
        string telegram;
    }

    struct FirstBuy {
        PoolKey poolKey;
        uint256 amountIn;
        address recipient;
    }

    struct LaunchSpec {
        address creator;
        address quote;
        uint256 firstBuyQuote;
        int24 initialTick;
        uint24 feeBps;
        uint16 creatorBps;
        uint16 holdersBps;
        address tokenDist;
        address feeDist;
    }

    mapping(address token => TokenMeta) public metaOf;

    address[] private _launches;

    event Launched(
        address indexed token,
        address indexed creator,
        uint256 indexed tokenId,
        PoolKey poolKey,
        uint24 fee,
        uint256 firstBuyIn
    );

    error OnlyPoolManager();
    error OnlyDeployer();
    error AlreadyInitialized();
    error NotInitialized();
    error BurnShareOutOfRange();
    error HoldersOutOfRange();
    error SellShareOutOfRange();
    error FeeOutOfRange();
    error NotAStockToken();
    error TokenSortsBelowQuote();
    error InitialTickOutOfRange();
    error ZeroFirstBuy();
    error FirstBuyBelowMinimum();
    error CreationFeeBelowMinimum();
    error TreasuryPaymentFailed();
    error RefundFailed();

    constructor(IPoolManager _poolManager, StockLocker _locker, IHooks _gate, IStockFactory _stockFactory) {
        poolManager = _poolManager;
        locker = _locker;
        gate = _gate;
        stockFactory = _stockFactory;
        deployer = msg.sender;
    }

    /// @notice One-time wiring of the distributor, callable only by the deployer.
    function initialize(IDistributor _distributor) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (address(distributor) != address(0)) revert AlreadyInitialized();
        distributor = _distributor;
    }

    /// @notice Launch a stock-quoted token on the creator tier. `quote` is the
    /// verified stock token, `firstBuyQuote` the first-buy amount pulled from the
    /// creator, `initialTick` the starting price, and `burnBps` the share of the
    /// creator's fee routed to buyback-and-burn.
    function launch(
        LaunchParams calldata p,
        TokenMeta calldata meta,
        address quote,
        uint256 firstBuyQuote,
        int24 initialTick,
        uint16 burnBps
    ) external payable nonReentrant returns (address token) {
        if (burnBps > CREATOR_TIER_SPLIT_BPS) revert BurnShareOutOfRange();
        // A burn dial needs somewhere to send the holder share, and the locker
        // fixes that recipient at launch. Refuse rather than record address(0).
        if (burnBps > 0 && address(distributor) == address(0)) revert NotInitialized();
        return _launch(
            p,
            meta,
            LaunchSpec({
                creator: msg.sender,
                quote: quote,
                firstBuyQuote: firstBuyQuote,
                initialTick: initialTick,
                feeBps: CREATOR_TIER_FEE,
                creatorBps: CREATOR_TIER_SPLIT_BPS - burnBps,
                holdersBps: burnBps,
                tokenDist: address(0),
                feeDist: burnBps > 0 ? address(distributor) : address(0)
            }),
            IDistributor.RewardConfig(0, 0, 10_000, 0)
        );
    }

    /// @notice Launch a stock-quoted token on the reflection tiers. Sets the pool
    /// fee, holder share, reward preset, and the share of token fees reflected to
    /// holders, in addition to the quote, first buy, and starting price.
    function launchReflection(
        LaunchParams calldata p,
        TokenMeta calldata meta,
        address quote,
        uint256 firstBuyQuote,
        int24 initialTick,
        uint24 feeBps,
        uint16 holdersBps,
        Preset preset,
        uint16 tokenReflectBps
    ) external payable nonReentrant returns (address token) {
        if (feeBps < MIN_REFLECTION_FEE || feeBps > MAX_REFLECTION_FEE) revert FeeOutOfRange();
        if (holdersBps < MIN_HOLDERS_BPS || holdersBps > MAX_HOLDERS_BPS) revert HoldersOutOfRange();
        if (tokenReflectBps > 10_000) revert SellShareOutOfRange();
        if (preset == Preset.EthPrinter || preset == Preset.Deflationary) {
            tokenReflectBps = 0;
        } else if (preset == Preset.Balanced && tokenReflectBps == 0) {
            revert SellShareOutOfRange();
        }
        uint16 stored = uint16(2 * uint256(holdersBps) - 10_000);
        // Register a distributor only where it would have work: a quote holder
        // share, or token-side reflections. With neither, no value ever reaches
        // it, token fees burn in the locker instead, and every transfer is
        // spared a checkpoint callback that could only no-op.
        bool needsDistributor = stored > 0 || tokenReflectBps > 0;
        // Same reasoning as `launch`: never record a live holder share against a
        // distributor that does not exist yet. See the note there.
        if (needsDistributor && address(distributor) == address(0)) revert NotInitialized();
        address dist = needsDistributor ? address(distributor) : address(0);

        token = _launch(
            p,
            meta,
            LaunchSpec({
                creator: msg.sender,
                quote: quote,
                firstBuyQuote: firstBuyQuote,
                initialTick: initialTick,
                feeBps: feeBps,
                creatorBps: uint16(2 * (10_000 - uint256(holdersBps) - PROTOCOL_BPS)),
                holdersBps: stored,
                tokenDist: dist,
                feeDist: dist
            }),
            _rewardConfig(preset, tokenReflectBps)
        );
    }

    /// @notice Verifies the stock quote, takes the creation fee, deploys the token,
    /// creates and locks the pool with the full supply, registers rewards, runs the
    /// first buy in the quote token, and refunds any excess ETH.
    function _launch(LaunchParams calldata p, TokenMeta calldata meta, LaunchSpec memory s, IDistributor.RewardConfig memory config)
        internal
        returns (address token)
    {
        if (msg.value < CREATION_FEE) revert CreationFeeBelowMinimum();
        if (s.firstBuyQuote == 0) revert ZeroFirstBuy();
        if (s.initialTick < MIN_INITIAL_TICK || s.initialTick > MAX_INITIAL_TICK || s.initialTick % TICK_SPACING != 0)
        {
            revert InitialTickOutOfRange();
        }
        _verifyStockQuote(s.quote);

        (bool ok,) = locker.treasury().call{value: CREATION_FEE}("");
        if (!ok) revert TreasuryPaymentFailed();

        token = _deployToken(p.salt, _tokenConfig(p, s.creator, s.tokenDist, s.feeDist));

        // Token must sort above the quote so the pool has currency0 = quote, currency1 = token.
        if (uint160(token) <= uint160(s.quote)) revert TokenSortsBelowQuote();

        metaOf[token] = meta;
        _launches.push(token);

        PoolKey memory poolKey = _poolKey(s.quote, token, s.feeBps);
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(s.initialTick));

        IERC20(token).transfer(address(locker), TOTAL_SUPPLY);
        uint256 tokenId = locker.lockLaunch(
            poolKey,
            s.creator,
            s.initialTick,
            s.creatorBps,
            s.holdersBps,
            _lpBps(s.feeBps),
            s.feeDist,
            TOTAL_SUPPLY
        );

        if (s.feeDist != address(0)) distributor.register(token, poolKey, config);

        IERC20(s.quote).safeTransferFrom(s.creator, address(this), s.firstBuyQuote);
        bytes memory res =
            poolManager.unlock(abi.encode(FirstBuy({poolKey: poolKey, amountIn: s.firstBuyQuote, recipient: s.creator})));

        // Gate on what the buy actually ACQUIRED, not on what was paid: the
        // amount paid is denominated in a quote this contract cannot price, and
        // the amount acquired is a share of a supply it fixed itself. Checked
        // after the swap because that is the only place the figure exists —
        // reverting here unwinds the whole launch atomically, so a first buy
        // that misses the floor costs the creator gas and nothing else.
        uint256 bought = abi.decode(res, (uint256));
        if (bought < TOTAL_SUPPLY * MIN_FIRST_BUY_SUPPLY_BPS / 10_000) revert FirstBuyBelowMinimum();

        emit Launched(token, s.creator, tokenId, poolKey, s.feeBps, s.firstBuyQuote);

        uint256 excess = msg.value - CREATION_FEE;
        if (excess > 0) {
            (bool refunded,) = msg.sender.call{value: excess}("");
            if (!refunded) revert RefundFailed();
        }
    }

    /// @notice Pool-manager callback that executes the first buy: swaps the quote
    /// token in for the launched token and sends it to the recipient. Only the pool
    /// manager may call.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        FirstBuy memory buy = abi.decode(data, (FirstBuy));

        BalanceDelta delta = poolManager.swap(
            buy.poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(buy.amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );

        poolManager.sync(buy.poolKey.currency0);
        IERC20(Currency.unwrap(buy.poolKey.currency0)).safeTransfer(address(poolManager), buy.amountIn);
        poolManager.settle();
        uint256 bought = uint256(uint128(delta.amount1()));
        poolManager.take(buy.poolKey.currency1, buy.recipient, bought);

        // Returned so `_launch` can enforce the minimum first buy against it.
        return abi.encode(bought);
    }

    /// @notice True if the quote is a token registered with the stock factory,
    /// confirmed by round-tripping its uid back to the same address.
    function isOfficialStock(address quote) public view returns (bool) {
        if (quote.code.length == 0) return false;
        try IStock(quote).uid() returns (bytes32 uid) {
            return stockFactory.tokenAddress(uid) == quote;
        } catch {
            return false;
        }
    }

    /// @notice Reverts unless the quote is a factory-verified stock token.
    function _verifyStockQuote(address quote) internal view {
        if (!isOfficialStock(quote)) revert NotAStockToken();
    }

    /// @notice True if the token was launched through this launchpad.
    function isArchrToken(address token) external view returns (bool) {
        (address creator,,,,,,,) = locker.launches(token);
        return creator != address(0);
    }

    function launchCount() external view returns (uint256) {
        return _launches.length;
    }

    function launchesFrom(uint256 start, uint256 n) external view returns (address[] memory out) {
        uint256 len = _launches.length;
        if (start >= len) return new address[](0);
        uint256 end = n > len - start ? len : start + n;
        out = new address[](end - start);
        for (uint256 i = start; i < end; ++i) out[i - start] = _launches[i];
    }

    /// @notice Predict the CREATE2 address of a token for the given launch params.
    function predictToken(LaunchParams calldata p, address creator, address dist) external view returns (address) {
        return predictToken(p, creator, dist, dist);
    }

    /// @notice Predict the CREATE2 address of a token, with an explicit fee sink.
    function predictToken(LaunchParams calldata p, address creator, address dist, address feeSink)
        public
        view
        returns (address)
    {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(ArchrToken).creationCode, _ctorArgs(_tokenConfig(p, creator, dist, feeSink))));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(this), p.salt, initCodeHash)))));
    }

    function _ctorArgs(ArchrToken.TokenConfig memory c) private pure returns (bytes memory) {
        return abi.encode(
            c.name,
            c.symbol,
            c.totalSupply,
            c.maxWalletBps,
            c.limitsWindowBlocks,
            c.creator,
            c.poolManager,
            c.locker,
            c.distributor,
            c.feeSink
        );
    }

    function _deployToken(bytes32 salt, ArchrToken.TokenConfig memory c) private returns (address) {
        return address(
            new ArchrToken{salt: salt}(
                c.name,
                c.symbol,
                c.totalSupply,
                c.maxWalletBps,
                c.limitsWindowBlocks,
                c.creator,
                c.poolManager,
                c.locker,
                c.distributor,
                c.feeSink
            )
        );
    }

    /// @notice The share of collected fees offered back to liquidity, sized so the
    /// ceiling is the same fraction of volume on every tier: a higher fee tier needs
    /// a smaller share of its fees to reach the same 0.20%. How much of it the
    /// compound can actually absorb is a separate question — see TARGET_LP_RATE.
    /// Always well below the creator and holder pool that funds it, since the
    /// smallest fee tier is 1% and that pool is never less than 70%; that margin is
    /// what keeps the payout subtraction in the locker from underflowing.
    function _lpBps(uint24 feeBps) internal pure returns (uint16) {
        return uint16(uint256(TARGET_LP_RATE) * 10_000 / feeBps);
    }

    function _poolKey(address quote, address token, uint24 feeBps) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(quote),
            currency1: Currency.wrap(token),
            fee: feeBps,
            tickSpacing: TICK_SPACING,
            hooks: gate
        });
    }

    function _tokenConfig(LaunchParams calldata p, address creator, address dist, address feeSink)
        internal
        view
        returns (ArchrToken.TokenConfig memory)
    {
        return ArchrToken.TokenConfig({
            name: p.name,
            symbol: p.symbol,
            totalSupply: TOTAL_SUPPLY,
            maxWalletBps: MAX_WALLET_BPS,
            limitsWindowBlocks: LIMITS_WINDOW_BLOCKS,
            creator: creator,
            poolManager: address(poolManager),
            locker: address(locker),
            distributor: dist,
            feeSink: feeSink
        });
    }

    /// @notice Translates a preset into the distributor reward configuration.
    function _rewardConfig(Preset preset, uint16 tokenReflectBps)
        internal
        pure
        returns (IDistributor.RewardConfig memory)
    {
        if (preset == Preset.Classic) {
            return IDistributor.RewardConfig(0, 10_000, 0, tokenReflectBps);
        } else if (preset == Preset.EthPrinter) {
            return IDistributor.RewardConfig(10_000, 0, 0, 0);
        } else if (preset == Preset.Deflationary) {
            return IDistributor.RewardConfig(0, 5000, 5000, 0);
        } else {
            return IDistributor.RewardConfig(10_000, 0, 0, tokenReflectBps);
        }
    }
}
