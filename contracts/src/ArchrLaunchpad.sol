// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {ArchrToken} from "./ArchrToken.sol";
import {ArchrLocker} from "./ArchrLocker.sol";
import {IDistributor} from "./interfaces/IDistributor.sol";

/**
 * @title ArchrLaunchpad
 * @notice Deploys a fixed-supply token, creates and seeds a permanently locked
 * Uniswap v4 pool quoted in ETH, and performs an atomic first buy. `launch`
 * opens a token on the 1% creator tier with an optional burn-dial share routed
 * to buyback-and-burn; `launchReflection` opens a token on the reflection tiers
 * with a configurable fee and holder split.
 */
contract ArchrLaunchpad is IUnlockCallback, ReentrancyGuard {
    int24 public constant TICK_SPACING = 200;
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    /// The standard launch curve, FDV ≈ 1.3557 ETH.
    int24 public constant INITIAL_TICK = 204_200;

    /// The starting FDV is `TOTAL_SUPPLY / 1.0001^tick`, so these bounds are a
    /// valuation range and a LOWER tick is a HIGHER valuation. The floor caps FDV
    /// at 15.24 ETH; the ceiling holds FDV at or above 0.224 ETH, which is what
    /// keeps the cost of acquiring a given share of supply from falling away with
    /// the opening valuation.
    int24 public constant MIN_INITIAL_TICK = 180_000;
    int24 public constant MAX_INITIAL_TICK = 222_200;

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

    uint256 public constant MIN_FIRST_BUY = 0.005 ether;

    /// Minimum first buy as a share of supply, which `MIN_FIRST_BUY` alone cannot
    /// fix because what a given spend acquires depends on `initialTick`. 10 bps of
    /// supply is exactly `MIN_DISTRIBUTION_SHARES`, so a launch opens able to
    /// distribute rather than with fee collection deferred.
    uint16 public constant MIN_FIRST_BUY_SUPPLY_BPS = 10;

    enum Preset {
        Classic,
        EthPrinter,
        Deflationary,
        Balanced
    }

    IPoolManager public immutable poolManager;
    ArchrLocker public immutable locker;
    IHooks public immutable gate;
    Currency public constant quote = CurrencyLibrary.ADDRESS_ZERO;
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
    error NotReflectionTier();
    error BurnShareOutOfRange();
    error HoldersOutOfRange();
    error SellShareOutOfRange();
    error FeeOutOfRange();
    error FirstBuyBelowMinimum();
    /// Distinct from `FirstBuyBelowMinimum`: the ether sent bought too small a
    /// share of supply at the chosen `initialTick`.
    error FirstBuyBelowSupplyFloor();
    error InitialTickOutOfRange();

    constructor(IPoolManager _poolManager, ArchrLocker _locker, IHooks _gate) {
        poolManager = _poolManager;
        locker = _locker;
        gate = _gate;
        deployer = msg.sender;
    }

    /// @notice One-time wiring of the distributor, callable only by the deployer.
    function initialize(IDistributor _distributor) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (address(distributor) != address(0)) revert AlreadyInitialized();
        distributor = _distributor;
    }

    /// @notice Launch a token on the creator tier. `burnBps` routes part of the
    /// creator's fee share to buyback-and-burn; the remainder pays the creator.
    /// The attached ETH is the first buy and must meet the minimum.
    function launch(LaunchParams calldata p, TokenMeta calldata meta, int24 initialTick, uint16 burnBps)
        external
        payable
        nonReentrant
        returns (address token)
    {
        if (burnBps > CREATOR_TIER_SPLIT_BPS) revert BurnShareOutOfRange();
        // A burn dial needs somewhere to send the holder share, and the locker
        // fixes that recipient at launch. Refuse rather than record address(0).
        if (burnBps > 0 && address(distributor) == address(0)) revert NotInitialized();
        return _launch(
            p,
            meta,
            LaunchSpec({
                creator: msg.sender,
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

    /// @notice Launch a token on the reflection tiers. Sets the pool fee, the
    /// holder share of fees, a reward preset, and the share of token fees
    /// reflected to holders. The attached ETH is the first buy.
    function launchReflection(
        LaunchParams calldata p,
        TokenMeta calldata meta,
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
        // Register a distributor only where it would have work. With neither a
        // holder share nor token reflections, fees burn in the locker instead and
        // transfers are spared a checkpoint that could only no-op.
        bool needsDistributor = stored > 0 || tokenReflectBps > 0;
        // Never record a live holder share against a distributor that does not
        // exist yet.
        if (needsDistributor && address(distributor) == address(0)) revert NotInitialized();
        address dist = needsDistributor ? address(distributor) : address(0);

        token = _launch(
            p,
            meta,
            LaunchSpec({
                creator: msg.sender,
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

    /// @notice Deploys the token at its CREATE2 address, creates and locks the pool
    /// with the whole supply as liquidity, registers rewards, and runs the first buy.
    function _launch(
        LaunchParams calldata p,
        TokenMeta calldata meta,
        LaunchSpec memory s,
        IDistributor.RewardConfig memory config
    ) internal returns (address token) {
        if (msg.value < MIN_FIRST_BUY) revert FirstBuyBelowMinimum();
        if (s.initialTick < MIN_INITIAL_TICK || s.initialTick > MAX_INITIAL_TICK || s.initialTick % TICK_SPACING != 0) {
            revert InitialTickOutOfRange();
        }

        token = _deployToken(p.salt, _tokenConfig(p, s.creator, s.tokenDist, s.feeDist));

        metaOf[token] = meta;
        _launches.push(token);

        PoolKey memory poolKey = _poolKey(token, s.feeBps);
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

        bytes memory res =
            poolManager.unlock(abi.encode(FirstBuy({poolKey: poolKey, amountIn: msg.value, recipient: s.creator})));

        // Gate on what the buy acquired as well as on what was paid. Checked
        // after the swap because that is the only place the figure exists;
        // reverting unwinds the whole launch atomically.
        uint256 bought = abi.decode(res, (uint256));
        if (bought < TOTAL_SUPPLY * MIN_FIRST_BUY_SUPPLY_BPS / 10_000) revert FirstBuyBelowSupplyFloor();

        emit Launched(token, s.creator, tokenId, poolKey, s.feeBps, msg.value);
    }

    /// @notice The share of collected fees offered back to liquidity, sized so
    /// the ceiling is the same fraction of volume on every tier. Always below the
    /// creator and holder pool that funds it, which is what keeps the locker's
    /// payout subtraction from underflowing.
    function _lpBps(uint24 feeBps) internal pure returns (uint16) {
        return uint16(uint256(TARGET_LP_RATE) * 10_000 / feeBps);
    }

    /// @notice Pool-manager callback executing the first buy. Only the pool
    /// manager may call. Returns the amount bought, for the supply floor check.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        FirstBuy memory buy = abi.decode(data, (FirstBuy));

        BalanceDelta delta = poolManager.swap(
            buy.poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(buy.amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );

        poolManager.sync(CurrencyLibrary.ADDRESS_ZERO);
        poolManager.settle{value: buy.amountIn}();
        uint256 bought = uint256(uint128(delta.amount1()));
        poolManager.take(buy.poolKey.currency1, buy.recipient, bought);

        return abi.encode(bought);
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

    function _poolKey(address token, uint24 feeBps) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: quote,
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
