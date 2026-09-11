// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ICheckpointReceiver} from "./interfaces/IDistributor.sol";

// Launched on archr.fun

/**
 * @title ArchrToken
 * @notice Fixed-supply ERC-20 deployed by the archr launchpad. During an initial
 * block window it enforces a per-wallet cap on inbound transfers; the creator and
 * addresses such as the pool manager, locker, distributor and fee sink are exempt
 * from it, for the whole window and for every inbound transfer. When a
 * distributor is set the token calls its checkpoint on every transfer so holder
 * reward shares stay in sync; otherwise transfers stay cheap. After the window
 * ends it behaves as a plain ERC-20.
 */
contract ArchrToken is ERC20 {
    struct TokenConfig {
        string name;
        string symbol;
        uint256 totalSupply;
        uint16 maxWalletBps;
        uint32 limitsWindowBlocks;
        address creator;
        address poolManager;
        address locker;
        address distributor;
        address feeSink;
    }

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 public immutable maxWalletAmount;
    uint256 public immutable limitsWindowEnd;
    address public immutable creator;
    address public immutable poolManager;
    address public immutable locker;
    address public immutable distributor;
    address public immutable feeSink;

    mapping(address => bool) public isExempt;

    error InvalidMaxWalletBps();
    error MaxWalletExceeded();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        uint16 maxWalletBps_,
        uint32 limitsWindowBlocks_,
        address creator_,
        address poolManager_,
        address locker_,
        address distributor_,
        address feeSink_
    ) ERC20(name_, symbol_) {
        if (maxWalletBps_ != 0 && (maxWalletBps_ < 100 || maxWalletBps_ > 500)) {
            revert InvalidMaxWalletBps();
        }

        maxWalletAmount = totalSupply_ * maxWalletBps_ / 10_000;
        // Block after which the max-wallet limit no longer applies.
        limitsWindowEnd = block.number + limitsWindowBlocks_;
        creator = creator_;
        poolManager = poolManager_;
        locker = locker_;
        distributor = distributor_;
        feeSink = feeSink_;

        isExempt[poolManager_] = true;
        isExempt[locker_] = true;
        isExempt[distributor_] = true;
        isExempt[feeSink_] = true;
        isExempt[msg.sender] = true;
        isExempt[DEAD] = true;
        isExempt[creator_] = true;

        _mint(msg.sender, totalSupply_);
    }

    /// @notice True while the initial max-wallet limit window is still open.
    function limitsActive() public view returns (bool) {
        return block.number <= limitsWindowEnd;
    }

    /// @notice Enforces the max-wallet cap during the limit window and, when a
    /// distributor is configured, checkpoints reward shares on every transfer.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (limitsActive() && from != address(0) && to != address(0) && !isExempt[to]) {
            if (maxWalletAmount != 0 && from != distributor && balanceOf(to) > maxWalletAmount) {
                revert MaxWalletExceeded();
            }
        }

        if (distributor != address(0)) {
            ICheckpointReceiver(distributor).checkpoint(from, to);
        }
    }
}
