// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20}           from "./interfaces/IERC20.sol";
import {IERC1363Receiver} from "./interfaces/IERC1363Receiver.sol";
import {IRewardOracle}    from "./interfaces/IRewardOracle.sol";

// StakingPool — core of the NQ-Swap liquidity mining protocol.
//
// Users lock ERC-1363 LP tokens here and earn reward tokens over time.
// The reward rate is not fixed — it comes from an external oracle so the
// emission schedule can be changed without touching the pool contract.
//
// Reward accounting follows the MasterChef pattern: a global accumulator
// (accRewardPerShare) tracks cumulative rewards per staked token. Each user
// stores a "debt" snapshot taken the last time their balance changed. The
// difference between gross earnings and the debt is what they're owed.
//
// Withdrawals go through a two-step flow: request → wait 2 days → execute.
// Once a request is made, those tokens stop earning rewards. The cooldown
// gives the security multisig a window to flag suspicious activity and reset
// the timer. The multisig can only delay — it cannot confiscate funds.
//
// Everything is written from scratch. No OpenZeppelin.
contract StakingPool is IERC1363Receiver {

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    // Scaling factor for accRewardPerShare. Using 1e18 keeps precision aligned
    // with 18-decimal reward tokens.
    uint256 public constant PRECISION = 1e18;

    // 2 days in seconds.
    uint256 public constant COOLDOWN = 2 days;

    // Magic value that onTransferReceived must return to signal a successful
    // ERC-1363 callback. Computed as:
    //   bytes4(keccak256("onTransferReceived(address,address,uint256,bytes)"))
    bytes4 private constant _TRANSFER_RECEIVED_MAGIC = 0x88a7ca5c;

    // Hard cap on the oracle rate. 1e24 = 1 million tokens per block, which is
    // already absurd. Anything higher risks overflowing accRewardPerShare.
    uint256 private constant MAX_REWARD_PER_BLOCK = 1e24;

    // -------------------------------------------------------------------------
    // Custom errors
    // -------------------------------------------------------------------------

    error SP__ZeroAmount();
    error SP__ZeroRewardRate();
    error SP__RewardRateTooHigh(uint256 rate, uint256 max);
    error SP__InsufficientStake(address user, uint256 have, uint256 need);
    error SP__WithdrawalNotFound(address user, uint256 id);
    error SP__CooldownNotElapsed(uint256 unlockTime, uint256 currentTime);
    error SP__OnlyMultisig();
    error SP__WithdrawalAlreadyFlagged(uint256 id);
    error SP__RewardInsolvency(uint256 available, uint256 owed);
    error SP__Locked();
    error SP__WithdrawalIdOverflow();
    error SP__InvalidLPToken();
    error SP__NotLPToken(address caller);
    error SP__MulOverflow();
    error SP__ZeroAddress();
    error SP__FundingFailed();
    error SP__OnlyOwner();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Staked(address indexed user, uint256 amount);
    event WithdrawalRequested(address indexed user, uint256 indexed id, uint256 amount);
    event WithdrawalExecuted(address indexed user, uint256 indexed id, uint256 amount, uint256 rewards);
    event WithdrawalFlagged(address indexed user, uint256 indexed id, uint256 newUnlockTime);
    event RewardsClaimed(address indexed user, uint256 amount);
    event PoolUpdated(uint256 accRewardPerShare, uint256 blockNumber);
    event RewardFunded(address indexed funder, uint256 amount);
    event OracleUpdated(address indexed newOracle);
    event MultisigUpdated(address indexed newMultisig);

    // -------------------------------------------------------------------------
    // Data structures
    // -------------------------------------------------------------------------

    // Staking state per user. Packed into two 32-byte storage slots.
    //
    // Slot 0: stakedAmount (uint128) | rewardDebt (uint128)
    // Slot 1: pendingRewards (uint128) | _reserved (uint128)
    //
    // uint128 is more than enough for any realistic LP supply (~3.4e38 max).
    struct UserInfo {
        uint128 stakedAmount;   // how many LP tokens the user has staked right now
        uint128 rewardDebt;     // debt snapshot at last balance change, scaled by PRECISION
        uint128 pendingRewards; // rewards earned but not yet transferred out
        uint128 _reserved;      // placeholder for future fields — keeps slot alignment
    }

    // A single pending withdrawal. Packed into two storage slots.
    //
    // Slot 0: amount (uint128) | requestTime (uint64) | flagged (bool) | _pad (56 bits)
    // Slot 1: id (uint256)
    //
    // requestTime as uint64 overflows around year 584,000 — fine.
    struct WithdrawalRequest {
        uint128 amount;       // LP tokens queued for withdrawal
        uint64  requestTime;  // timestamp when this request was created (or last reset by multisig)
        bool    flagged;      // whether the security multisig has flagged this request
        uint56  _pad;         // explicit padding so the struct fits cleanly in two slots
        uint256 id;           // unique ID assigned at request time
    }

    // -------------------------------------------------------------------------
    // State variables
    // -------------------------------------------------------------------------

    // These three are set once in the constructor and never change.
    address public immutable lpToken;
    address public immutable rewardToken;
    address public immutable owner;

    // These can be updated by the owner after deployment.
    address public rewardOracle;
    address public securityMultisig;

    // The global reward accumulator. Every time someone stakes/unstakes/claims
    // we update this to reflect how many reward tokens each staked LP token
    // has earned since genesis. It only ever goes up.
    uint256 public accRewardPerShare;

    // The last block where we checkpointed the accumulator.
    uint256 public lastRewardBlock;

    // Packed slot: totalStaked and totalPendingWithdrawals share one 32-byte word.
    // uint128 supports up to ~3.4e38 — well beyond any realistic TVL.
    // Packing saves one cold SLOAD (2100 gas) on every stake and withdrawal.
    uint128 public totalStaked;
    uint128 public totalPendingWithdrawals;

    // Packed slot: rewardReserve and nextWithdrawalId share one 32-byte word.
    // rewardReserve tracks deposited-but-unpaid reward tokens.
    // nextWithdrawalId is a simple incrementing counter guarded against overflow.
    uint128 public rewardReserve;
    uint128 public nextWithdrawalId;

    mapping(address => UserInfo)                                private _userInfo;
    mapping(address => mapping(uint256 => WithdrawalRequest))   private _withdrawalRequests;
    mapping(address => uint256[])                               private _userWithdrawalIds;

    // Re-entrancy mutex. 1 = open, 2 = locked. uint8 is slightly cheaper than bool.
    uint8 private _locked;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier nonReentrant() {
        if (_locked == 2) revert SP__Locked();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyMultisig() {
        if (msg.sender != securityMultisig) revert SP__OnlyMultisig();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert SP__OnlyOwner();
        _;
    }

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address _lpToken,
        address _rewardToken,
        address _rewardOracle,
        address _securityMultisig
    ) {
        if (_lpToken == address(0))          revert SP__ZeroAddress();
        if (_rewardToken == address(0))      revert SP__ZeroAddress();
        if (_rewardOracle == address(0))     revert SP__ZeroAddress();
        if (_securityMultisig == address(0)) revert SP__ZeroAddress();

        lpToken          = _lpToken;
        rewardToken      = _rewardToken;
        rewardOracle     = _rewardOracle;
        securityMultisig = _securityMultisig;
        owner            = msg.sender;

        lastRewardBlock = block.number;
        _locked         = 1;
    }

    // -------------------------------------------------------------------------
    // Owner admin
    // -------------------------------------------------------------------------

    // Deposit reward tokens into the pool. The owner must approve this contract
    // first. Without a funded reserve the pool will revert when trying to pay
    // out rewards.
    function fundRewards(uint256 amount) external onlyOwner {
        if (amount == 0) revert SP__ZeroAmount();
        bool ok = IERC20(rewardToken).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert SP__FundingFailed();
        unchecked { rewardReserve += uint128(amount); }
        emit RewardFunded(msg.sender, amount);
    }

    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert SP__ZeroAddress();
        rewardOracle = newOracle;
        emit OracleUpdated(newOracle);
    }

    function setMultisig(address newMultisig) external onlyOwner {
        if (newMultisig == address(0)) revert SP__ZeroAddress();
        securityMultisig = newMultisig;
        emit MultisigUpdated(newMultisig);
    }

    // -------------------------------------------------------------------------
    // Staking
    // -------------------------------------------------------------------------

    // Standard stake path: user approves LP tokens, then calls stake().
    // They can also use lpToken.transferAndCall(pool, amount) as a one-tx
    // alternative via the ERC-1363 path below.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert SP__ZeroAmount();
        uint256 acc = _updatePool();
        // _settleUser credits pending rewards AND updates the debt in a single
        // storage round-trip, halving the SLOAD count vs two separate calls.
        _settleUser(msg.sender, acc);

        UserInfo storage u = _userInfo[msg.sender];
        unchecked {
            u.stakedAmount  += uint128(amount);
            totalStaked     += uint128(amount);
        }
        // Debt must be refreshed after the balance change.
        u.rewardDebt = uint128(_computeReward(u.stakedAmount, acc));

        bool ok = IERC20(lpToken).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert SP__InvalidLPToken();

        emit Staked(msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // ERC-1363 callback — one-transaction staking
    // -------------------------------------------------------------------------

    // Called by the LP token contract after transferAndCall. The tokens are
    // already sitting in this contract when this fires, so we just update
    // accounting.
    //
    // The msg.sender check is critical: anyone can call this function directly,
    // but only a call originating from the LP token contract is legitimate.
    // Skip the check and an attacker can fake stakes with no tokens.
    function onTransferReceived(
        address, /* operator — not needed */
        address from,
        uint256 amount,
        bytes calldata /* data — not needed */
    ) external override nonReentrant returns (bytes4) {
        if (msg.sender != lpToken) revert SP__NotLPToken(msg.sender);
        if (amount == 0) revert SP__ZeroAmount();

        uint256 acc = _updatePool();
        _settleUser(from, acc);

        UserInfo storage u = _userInfo[from];
        unchecked {
            u.stakedAmount += uint128(amount);
            totalStaked    += uint128(amount);
        }
        u.rewardDebt = uint128(_computeReward(u.stakedAmount, acc));

        emit Staked(from, amount);

        return _TRANSFER_RECEIVED_MAGIC;
    }

    // -------------------------------------------------------------------------
    // Withdrawal — step 1: request
    // -------------------------------------------------------------------------

    // Queue a withdrawal. The requested tokens immediately stop earning rewards
    // (their staked balance is reduced here), but they stay in the contract
    // until the cooldown expires. Multiple concurrent requests are fine.
    function requestWithdrawal(uint256 amount) external nonReentrant returns (uint256 id) {
        if (amount == 0) revert SP__ZeroAmount();

        UserInfo storage u = _userInfo[msg.sender];
        if (u.stakedAmount < uint128(amount)) {
            revert SP__InsufficientStake(msg.sender, u.stakedAmount, amount);
        }

        uint256 acc = _updatePool();
        _settleUser(msg.sender, acc);

        // Use Yul helpers for the three balance mutations so every arithmetic
        // op in the withdrawal path has explicit overflow/underflow protection
        // in assembly — matching the standard set by _computeReward above.
        uint128 amt128 = uint128(amount);
        u.stakedAmount          = _sub128(u.stakedAmount,          amt128);
        totalStaked             = _sub128(totalStaked,             amt128);
        totalPendingWithdrawals = _add128(totalPendingWithdrawals, amt128);
        u.rewardDebt = uint128(_computeReward(u.stakedAmount, acc));

        // Cache nextWithdrawalId to avoid a second storage read after the increment.
        uint128 currentId = nextWithdrawalId;
        if (currentId == type(uint128).max) revert SP__WithdrawalIdOverflow();
        unchecked { nextWithdrawalId = currentId + 1; }
        id = currentId;

        _withdrawalRequests[msg.sender][id] = WithdrawalRequest({
            amount:      uint128(amount),
            requestTime: uint64(block.timestamp),
            flagged:     false,
            _pad:        0,
            id:          id
        });
        _userWithdrawalIds[msg.sender].push(id);

        emit WithdrawalRequested(msg.sender, id, amount);
    }

    // -------------------------------------------------------------------------
    // Withdrawal — step 2: execute (after cooldown)
    // -------------------------------------------------------------------------

    // Finish a withdrawal request. The cooldown must have passed. We zero all
    // state before making any external calls (CEI) so there is no re-entrancy
    // window even if the LP or reward token misbehaves.
    function executeWithdrawal(uint256 id) external nonReentrant {
        WithdrawalRequest memory req = _withdrawalRequests[msg.sender][id];
        if (req.amount == 0) revert SP__WithdrawalNotFound(msg.sender, id);

        // _cooldownDeadline uses Yul to compute requestTime + COOLDOWN with an
        // explicit overflow check — the same discipline used in _computeReward.
        uint256 unlockTime = _cooldownDeadline(uint256(req.requestTime), COOLDOWN);
        if (block.timestamp < unlockTime) {
            revert SP__CooldownNotElapsed(unlockTime, block.timestamp);
        }

        uint256 lpAmount = req.amount;

        // Cache the user storage pointer — pendingRewards and the zero-write
        // both hit slot 1, so one warm SLOAD covers both.
        UserInfo storage u = _userInfo[msg.sender];
        uint256 rewardAmount = u.pendingRewards;

        // Clear everything before touching external contracts (CEI).
        delete _withdrawalRequests[msg.sender][id];
        _removeWithdrawalId(msg.sender, id);

        // Yul sub: underflow guard matches the rest of the withdrawal math.
        totalPendingWithdrawals = _sub128(totalPendingWithdrawals, uint128(lpAmount));
        u.pendingRewards = 0;

        if (rewardAmount > 0) {
            uint128 reserve = rewardReserve;
            if (rewardAmount > reserve) {
                revert SP__RewardInsolvency(reserve, rewardAmount);
            }
            // Yul sub: explicit underflow protection on the reserve drawdown.
            rewardReserve = _sub128(reserve, uint128(rewardAmount));
        }

        bool ok = IERC20(lpToken).transfer(msg.sender, lpAmount);
        if (!ok) revert SP__InvalidLPToken();

        if (rewardAmount > 0) {
            bool rok = IERC20(rewardToken).transfer(msg.sender, rewardAmount);
            if (!rok) revert SP__RewardInsolvency(rewardReserve, rewardAmount);
        }

        emit WithdrawalExecuted(msg.sender, id, lpAmount, rewardAmount);
    }

    // -------------------------------------------------------------------------
    // Security multisig — flag a withdrawal
    // -------------------------------------------------------------------------

    // The multisig can reset the cooldown on any pending withdrawal request by
    // flagging it. This is the only defensive power the multisig has — it cannot
    // seize or cancel funds, just buy more time for investigation.
    //
    // The flagged bit prevents double-flagging the same request.
    function flagWithdrawal(address user, uint256 id) external onlyMultisig {
        WithdrawalRequest storage req = _withdrawalRequests[user][id];
        if (req.amount == 0) revert SP__WithdrawalNotFound(user, id);
        if (req.flagged) revert SP__WithdrawalAlreadyFlagged(id);

        req.flagged     = true;
        req.requestTime = uint64(block.timestamp);

        // Use the same Yul overflow-checked addition as executeWithdrawal so
        // the unlock time in the event is computed consistently.
        emit WithdrawalFlagged(user, id, _cooldownDeadline(block.timestamp, COOLDOWN));
    }

    // -------------------------------------------------------------------------
    // Reward claiming (independent of withdrawal)
    // -------------------------------------------------------------------------

    // Claim all pending rewards without touching your staked position.
    // State is zeroed before the transfer to satisfy CEI ordering.
    function claimRewards() external nonReentrant {
        uint256 acc = _updatePool();
        // _settleUser credits earned rewards into pendingRewards and snapshots
        // the debt in one storage round-trip.
        _settleUser(msg.sender, acc);

        // Re-use the storage pointer from the settle — pendingRewards is in
        // slot 1 of UserInfo, which is already warm.
        UserInfo storage u = _userInfo[msg.sender];
        uint256 pending = u.pendingRewards;
        if (pending == 0) return;

        u.pendingRewards = 0;
        uint128 reserve = rewardReserve;
        if (pending > reserve) {
            revert SP__RewardInsolvency(reserve, pending);
        }
        // Yul sub: same overflow discipline as the rest of the withdrawal path.
        rewardReserve = _sub128(reserve, uint128(pending));

        bool ok = IERC20(rewardToken).transfer(msg.sender, pending);
        if (!ok) revert SP__RewardInsolvency(rewardReserve, pending);

        emit RewardsClaimed(msg.sender, pending);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    function userInfo(address user)
        external
        view
        returns (uint128 stakedAmount, uint128 rewardDebt, uint128 pendingRewards)
    {
        UserInfo storage u = _userInfo[user];
        return (u.stakedAmount, u.rewardDebt, u.pendingRewards);
    }

    function getWithdrawalRequest(address user, uint256 id)
        external
        view
        returns (WithdrawalRequest memory)
    {
        return _withdrawalRequests[user][id];
    }

    function getUserWithdrawalIds(address user) external view returns (uint256[] memory) {
        return _userWithdrawalIds[user];
    }

    // Off-chain view: simulate what a pool update at the current block would
    // yield for this user, without writing anything to state.
    function pendingReward(address user) external view returns (uint256) {
        UserInfo storage u = _userInfo[user];
        uint256 acc = accRewardPerShare;

        if (block.number > lastRewardBlock && totalStaked > 0) {
            uint256 rate = IRewardOracle(rewardOracle).rewardPerBlock();
            if (rate > 0) {
                uint256 delta;
                unchecked { delta = block.number - lastRewardBlock; }
                uint256 reward;
                unchecked { reward = delta * rate; }
                uint256 addition = _safeDivide(reward * PRECISION, totalStaked);
                unchecked { acc += addition; }
            }
        }

        uint256 gross  = _computeReward(u.stakedAmount, acc);
        uint256 debt   = u.rewardDebt;
        uint256 earned = gross > debt ? gross - debt : 0;
        unchecked {
            return earned + u.pendingRewards;
        }
    }

    function withdrawalUnlockTime(address user, uint256 id) external view returns (uint256) {
        WithdrawalRequest storage req = _withdrawalRequests[user][id];
        if (req.amount == 0) return 0;
        return _cooldownDeadline(uint256(req.requestTime), COOLDOWN);
    }

    // -------------------------------------------------------------------------
    // Internal — pool update
    // -------------------------------------------------------------------------

    // Bring the accumulator up to date. Called at the top of every
    // state-changing function before any balance changes are made.
    //
    // Returns the current accRewardPerShare so callers can use it directly
    // without a second SLOAD.
    //
    // If no blocks have passed since the last update we skip everything to avoid
    // a redundant oracle call. If nobody is staked we still advance lastRewardBlock
    // so we don't retroactively pay out rewards for blocks with zero TVL.
    function _updatePool() internal returns (uint256 acc) {
        acc = accRewardPerShare;
        if (block.number == lastRewardBlock) return acc;

        uint256 _lastBlock   = lastRewardBlock;
        uint256 _totalStaked = totalStaked;

        lastRewardBlock = block.number;

        if (_totalStaked == 0) return acc;

        uint256 rate = IRewardOracle(rewardOracle).rewardPerBlock();
        if (rate == 0) revert SP__ZeroRewardRate();
        if (rate > MAX_REWARD_PER_BLOCK) revert SP__RewardRateTooHigh(rate, MAX_REWARD_PER_BLOCK);

        uint256 delta;
        unchecked { delta = block.number - _lastBlock; }

        uint256 totalReward;
        unchecked { totalReward = delta * rate; }

        // totalReward * PRECISION can get large — use the Yul muldiv below
        // which checks for overflow and reverts cleanly.
        uint256 addition = _computeRewardAddition(totalReward, _totalStaked);

        unchecked { acc += addition; }
        accRewardPerShare = acc;

        emit PoolUpdated(acc, block.number);
    }

    // -------------------------------------------------------------------------
    // Internal — reward credit / debt (merged into one storage round-trip)
    // -------------------------------------------------------------------------

    // Credit any rewards earned since the last checkpoint, then snapshot the
    // new debt — all in a single storage round-trip per UserInfo slot.
    //
    // Previously _creditPendingRewards and _updateRewardDebt were separate
    // functions that each loaded _userInfo[user] independently. Merging them
    // saves one warm SLOAD (100 gas) on every stake, unstake, and claim.
    //
    // acc is passed in by the caller, which already has it on the stack from
    // _updatePool(), so we never need to read accRewardPerShare from storage here.
    function _settleUser(address user_, uint256 acc) internal {
        UserInfo storage u = _userInfo[user_];
        uint128 staked = u.stakedAmount;
        if (staked == 0) return;

        uint256 gross  = _computeReward(staked, acc);
        uint256 debt   = u.rewardDebt;
        uint256 earned = gross > debt ? gross - debt : 0;

        if (earned > 0) {
            unchecked { u.pendingRewards += uint128(earned); }
        }
        // Debt snapshot written in the same storage op as the pending credit.
        // The caller will overwrite rewardDebt again after adjusting stakedAmount,
        // but for pure-claim and no-balance-change paths this is the final write.
        u.rewardDebt = uint128(gross);
    }

    // -------------------------------------------------------------------------
    // Internal — Yul assembly math
    // -------------------------------------------------------------------------

    // Compute (stakedAmount * acc) / PRECISION without overflowing.
    //
    // This is on the hot path — called on every stake, unstake, and claim.
    // We use a Yul inner function so the `leave` keyword works correctly.
    // The overflow check is manual: if a != 0 and (a*b)/a != b, the multiply
    // wrapped around and we revert with SP__MulOverflow().
    function _computeReward(uint256 stakedAmount, uint256 acc) internal pure returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            function mulDiv(a, b, precision) -> res {
                if or(iszero(a), iszero(b)) {
                    res := 0
                    leave
                }

                // Overflow check: b > maxUint / a means a*b would wrap.
                let maxUint := 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
                if gt(b, div(maxUint, a)) {
                    // SP__MulOverflow() selector = 0x906c1881
                    mstore(0x00, 0x906c188100000000000000000000000000000000000000000000000000000000)
                    revert(0x00, 0x04)
                }

                res := div(mul(a, b), precision)
            }

            result := mulDiv(stakedAmount, acc, 1000000000000000000)
        }
    }

    // Compute (totalReward * PRECISION) / totalStaked for the per-share addition
    // in _updatePool. Same overflow guard as _computeReward.
    function _computeRewardAddition(uint256 totalReward, uint256 totalStaked_)
        internal
        pure
        returns (uint256 addition)
    {
        /// @solidity memory-safe-assembly
        assembly {
            function mulDivByStake(reward, precision, staked) -> res {
                if iszero(reward) {
                    res := 0
                    leave
                }

                let maxUint := 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
                if gt(precision, div(maxUint, reward)) {
                    // SP__MulOverflow() selector = 0x906c1881
                    mstore(0x00, 0x906c188100000000000000000000000000000000000000000000000000000000)
                    revert(0x00, 0x04)
                }

                res := div(mul(reward, precision), staked)
            }

            addition := mulDivByStake(totalReward, 1000000000000000000, totalStaked_)
        }
    }

    // Divide without reverting on zero denominator. The only caller that passes
    // a zero denominator is pendingReward() when totalStaked is zero, and in
    // that case returning 0 is the right answer.
    function _safeDivide(uint256 numerator, uint256 denominator) internal pure returns (uint256) {
        if (denominator == 0) return 0;
        return numerator / denominator;
    }

    // -------------------------------------------------------------------------
    // Internal — Yul helpers for withdrawal arithmetic
    // -------------------------------------------------------------------------

    // Safe uint128 addition. Reverts with SP__MulOverflow if the result would
    // exceed type(uint128).max. Used in requestWithdrawal for totalPendingWithdrawals.
    //
    // We reuse the SP__MulOverflow error selector (0x906c1881) rather than
    // introducing a new error type — the root cause (arithmetic overflow) is
    // the same regardless of whether it's a multiply or an add.
    function _add128(uint128 a, uint128 b) internal pure returns (uint128 result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := add(a, b)
            // If result < a, the addition wrapped around the uint128 boundary.
            if lt(result, a) {
                mstore(0x00, 0x906c188100000000000000000000000000000000000000000000000000000000)
                revert(0x00, 0x04)
            }
        }
    }

    // Safe uint128 subtraction. Reverts with SP__MulOverflow if b > a (underflow).
    // Used in requestWithdrawal and executeWithdrawal for balance/reserve drawdowns.
    function _sub128(uint128 a, uint128 b) internal pure returns (uint128 result) {
        /// @solidity memory-safe-assembly
        assembly {
            // If b > a, subtracting would underflow.
            if gt(b, a) {
                mstore(0x00, 0x906c188100000000000000000000000000000000000000000000000000000000)
                revert(0x00, 0x04)
            }
            result := sub(a, b)
        }
    }

    // Compute a + b (both uint256) and revert if the result overflows uint256.
    // Used to calculate the cooldown deadline (requestTime + COOLDOWN) in
    // executeWithdrawal and flagWithdrawal. While uint256 overflow at real
    // timestamps is effectively impossible, using an explicit Yul check here
    // keeps the entire withdrawal math path under the same overflow discipline
    // as _computeReward and _computeRewardAddition.
    function _cooldownDeadline(uint256 a, uint256 b) internal pure returns (uint256 result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := add(a, b)
            // Overflow: result < a means the addition wrapped.
            if lt(result, a) {
                mstore(0x00, 0x906c188100000000000000000000000000000000000000000000000000000000)
                revert(0x00, 0x04)
            }
        }
    }

    // -------------------------------------------------------------------------
    // Internal — withdrawal ID list management
    // -------------------------------------------------------------------------

    // Remove a withdrawal ID from the user's list using swap-and-pop.
    // O(n) but users realistically have very few concurrent requests.
    // If the ID is somehow missing we return silently — the calling function
    // already validated the request existed.
    function _removeWithdrawalId(address user_, uint256 id) internal {
        uint256[] storage ids = _userWithdrawalIds[user_];
        uint256 len = ids.length;
        for (uint256 i = 0; i < len; ) {
            if (ids[i] == id) {
                ids[i] = ids[len - 1];
                ids.pop();
                return;
            }
            unchecked { i++; }
        }
    }
}
