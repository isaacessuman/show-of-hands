// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OneVoice, IAgentID} from "./lib/OneVoice.sol";

/// @title Show of Hands — Funding Rounds
/// @notice Quadratic funding paid in native BNB, where each Agent ID is exactly one backer.
///
///         Holders back builders and creators with small BNB gifts. A matching pool, put up in advance, is split by
///         how many *different* Agent IDs back each project, not by how much any one of them paid:
///             weight(project) = (Σ sqrt(paid by each Agent ID))² − Σ paid
///         Without one-name-per-account, one person with many wallets could drain the pool. Agent ID blocks that.
///
/// @dev    Money rules (the whole list):
///         • Money enters only through createRound, topUpPool and back.
///         • Money leaves only through claim (project wallet), refund (backer) and withdrawPool (pool funder).
///         • No owner, no admin, no fee, no upgrade path, no function that sends money anywhere else.
///         • Exits never read the Agent ID registry, so a registry fault cannot lock funds.
///         The only special role is each round's steward (the Agent ID holder who opened it). Before the round is
///         finalised the steward can approve or delist projects and cancel the round. Delisting refunds that
///         project's backers; cancelling refunds every backer and every pool funder. The steward can never take
///         backers' money.
contract FundingRounds is OneVoice {
    // ------------------------------------------------------------ constants

    uint256 public constant MIN_SEED = 0.01 ether;
    uint256 public constant MIN_BACKERS_FOR_MATCH = 5;
    uint256 public constant MAX_APPROVED_PROJECTS = 40;
    uint256 public constant MAX_APPLICATIONS = 200;
    uint256 public constant MAX_PROJECTS_PER_BACK = 10;
    uint256 public constant REVIEW_PERIOD = 24 hours;
    uint256 public constant MAX_ROUND_LENGTH = 60 days;
    uint256 public constant MAX_START_DELAY = 30 days;
    uint256 public constant MIN_CAP_BPS = 500; // 5%
    uint256 public constant MAX_TITLE_BYTES = 120;
    uint256 public constant MAX_NAME_BYTES = 64;
    uint256 public constant MAX_URL_BYTES = 200;
    uint256 private constant BPS = 10_000;

    // ---------------------------------------------------------------- types

    enum Status {
        None,
        Pending,
        Approved,
        Delisted
    }

    struct Round {
        address steward;
        bytes32 stewardVoice;
        uint64 startsAt;
        uint64 endsAt;
        uint128 minPerBacker; // per backer per project
        uint128 maxPerBacker; // per backer per project
        uint16 capBps; // max share of the pool one project can take
        bool finalised;
        bool cancelled;
        uint256 pool; // total matching money ever put in
        uint256 matchedTotal; // matching money assigned at finalise
        uint256 approvedCount;
        string title;
    }

    struct Project {
        address wallet; // receives the payout; the Agent ID holder who applied
        bytes32 voice;
        Status status;
        bool claimed;
        uint32 backers; // distinct Agent IDs
        uint256 raised; // direct backing in wei
        uint256 sumSqrt; // Σ sqrt(paid by each Agent ID), in sqrt(wei)
        uint256 matched; // set at finalise
        string name;
        string url;
    }

    // -------------------------------------------------------------- storage

    Round[] private _rounds;
    mapping(uint256 roundId => Project[]) private _projects;
    mapping(uint256 roundId => uint256[]) private _approvedIds;
    mapping(uint256 roundId => mapping(bytes32 voice => uint256)) public projectOfVoice; // project id + 1

    /// @notice round => project => voice => wei paid (the quadratic input; caps apply here)
    mapping(uint256 => mapping(uint256 => mapping(bytes32 => uint256))) public paidByVoice;
    /// @notice round => project => wallet => wei refundable if the project is delisted or the round cancelled
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public paidByWallet;
    /// @notice round => wallet => matching money that wallet put into the pool
    mapping(uint256 => mapping(address => uint256)) public poolFundedBy;
    /// @notice round => wallet => already withdrew its unused pool share
    mapping(uint256 => mapping(address => bool)) public poolWithdrawn;
    /// @notice round => voice => number of distinct projects this Agent ID backed (public activity count)
    mapping(uint256 => mapping(bytes32 => uint32)) public projectsBackedBy;

    uint256 private _lock = 1;

    // --------------------------------------------------------------- events

    event RoundCreated(
        uint256 indexed roundId,
        address indexed steward,
        bytes32 indexed stewardVoice,
        uint64 startsAt,
        uint64 endsAt,
        uint128 minPerBacker,
        uint128 maxPerBacker,
        uint16 capBps,
        uint256 seed,
        string title
    );
    event PoolToppedUp(uint256 indexed roundId, address indexed funder, uint256 amount);
    event ProjectApplied(
        uint256 indexed roundId, uint256 indexed projectId, address indexed wallet, bytes32 voice, string name, string url
    );
    event ProjectApproved(uint256 indexed roundId, uint256 indexed projectId);
    event ProjectDelisted(uint256 indexed roundId, uint256 indexed projectId, string reason);
    event Backed(
        uint256 indexed roundId, uint256 indexed projectId, bytes32 indexed voice, address backer, uint256 amount
    );
    event RoundCancelled(uint256 indexed roundId, string reason);
    event RoundFinalised(uint256 indexed roundId, uint256 matchedTotal, uint256 unusedPool);
    event Claimed(uint256 indexed roundId, uint256 indexed projectId, address indexed wallet, uint256 amount);
    event Refunded(uint256 indexed roundId, uint256 indexed projectId, address indexed backer, uint256 amount);
    event PoolWithdrawn(uint256 indexed roundId, address indexed funder, uint256 amount);

    // --------------------------------------------------------------- errors

    error Reentrancy();
    error NoSuchRound();
    error NoSuchProject();
    error SeedTooSmall();
    error BadTimes();
    error BadLimits();
    error BadCap();
    error BadText();
    error NotSteward();
    error RoundIsFinal();
    error RoundNotOpen();
    error RoundEnded();
    error AlreadyApplied();
    error TooManyProjects();
    error WrongStatus();
    error BadAmounts();
    error OwnProject();
    error WalletMismatch();
    error ReviewNotOver();
    error NotFinalised();
    error NotProjectWallet();
    error AlreadyClaimed();
    error NothingToRefund();
    error NothingToWithdraw();
    error TransferFailed();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(IAgentID registry) OneVoice(registry) {}

    // ======================================================== steward actions

    /// @notice Open a round. The caller (an Agent ID holder) becomes its steward and seeds the matching pool.
    ///         Dates, limits and cap are fixed for good.
    function createRound(
        string calldata title,
        uint64 startsAt,
        uint64 endsAt,
        uint128 minPerBacker,
        uint128 maxPerBacker,
        uint16 capBps
    ) external payable returns (uint256 roundId) {
        bytes32 voice = _voiceOf(msg.sender);
        if (msg.value < MIN_SEED) revert SeedTooSmall();
        // A start time already passed when the transaction lands means "start now".
        if (startsAt < block.timestamp) startsAt = uint64(block.timestamp);
        if (
            startsAt > block.timestamp + MAX_START_DELAY || endsAt <= startsAt
                || endsAt - startsAt > MAX_ROUND_LENGTH
        ) revert BadTimes();
        if (minPerBacker == 0 || maxPerBacker < minPerBacker) revert BadLimits();
        if (capBps < MIN_CAP_BPS || capBps > BPS) revert BadCap();
        _text(title, MAX_TITLE_BYTES);

        roundId = _rounds.length;
        Round storage r = _rounds.push();
        r.steward = msg.sender;
        r.stewardVoice = voice;
        r.startsAt = startsAt;
        r.endsAt = endsAt;
        r.minPerBacker = minPerBacker;
        r.maxPerBacker = maxPerBacker;
        r.capBps = capBps;
        r.pool = msg.value;
        r.title = title;
        poolFundedBy[roundId][msg.sender] = msg.value;

        emit RoundCreated(roundId, msg.sender, voice, startsAt, endsAt, minPerBacker, maxPerBacker, capBps, msg.value, title);
        emit PoolToppedUp(roundId, msg.sender, msg.value);
    }

    /// @notice Admit a pending project so it can be backed. Steward only, before the round ends.
    function approveProject(uint256 roundId, uint256 projectId) external {
        Round storage r = _steward(roundId);
        if (block.timestamp >= r.endsAt) revert RoundEnded();
        Project storage p = _project(roundId, projectId);
        if (p.status != Status.Pending) revert WrongStatus();
        if (r.approvedCount >= MAX_APPROVED_PROJECTS) revert TooManyProjects();
        p.status = Status.Approved;
        r.approvedCount += 1;
        _approvedIds[roundId].push(projectId);
        emit ProjectApproved(roundId, projectId);
    }

    /// @notice Remove a project (pending or approved) and unlock refunds for its backers. Steward only, before
    ///         finalise. The reason is published on-chain.
    function delistProject(uint256 roundId, uint256 projectId, string calldata reason) external {
        _steward(roundId);
        Project storage p = _project(roundId, projectId);
        if (p.status != Status.Pending && p.status != Status.Approved) revert WrongStatus();
        // approvedCount is not decreased: a delisted slot stays used, so delisting cannot be used to swap projects
        // in late. finalise skips delisted projects.
        p.status = Status.Delisted;
        emit ProjectDelisted(roundId, projectId, reason);
    }

    /// @notice Cancel the whole round before finalise. Every backer and every pool funder can then take back
    ///         exactly what they put in.
    function cancelRound(uint256 roundId, string calldata reason) external {
        Round storage r = _steward(roundId);
        r.cancelled = true;
        emit RoundCancelled(roundId, reason);
    }

    // ========================================================== holder actions

    /// @notice List a project in a round. Caller must hold an Agent ID; the caller's wallet will receive the payout.
    ///         One project per Agent ID per round. The project starts as pending until the steward approves it.
    function applyProject(uint256 roundId, string calldata name, string calldata url)
        external
        returns (uint256 projectId)
    {
        Round storage r = _round(roundId);
        if (r.finalised || r.cancelled) revert RoundIsFinal();
        if (block.timestamp >= r.endsAt) revert RoundEnded();
        bytes32 voice = _voiceOf(msg.sender);
        if (projectOfVoice[roundId][voice] != 0) revert AlreadyApplied();
        if (_projects[roundId].length >= MAX_APPLICATIONS) revert TooManyProjects();
        _text(name, MAX_NAME_BYTES);
        if (bytes(url).length > MAX_URL_BYTES) revert BadText();

        projectId = _projects[roundId].length;
        Project storage p = _projects[roundId].push();
        p.wallet = msg.sender;
        p.voice = voice;
        p.status = Status.Pending;
        p.name = name;
        p.url = url;
        projectOfVoice[roundId][voice] = projectId + 1;

        emit ProjectApplied(roundId, projectId, msg.sender, voice, name, url);
    }

    /// @notice Back one or more approved projects with BNB. `amounts[i]` goes to `projectIds[i]` and they must add
    ///         up to the BNB sent. The money stays in this contract until the project claims it after the round.
    ///         Each Agent ID's total per project must stay between the round's minimum and maximum.
    function back(uint256 roundId, uint256[] calldata projectIds, uint256[] calldata amounts)
        external
        payable
        nonReentrant
    {
        Round storage r = _round(roundId);
        if (r.cancelled || r.finalised) revert RoundIsFinal();
        if (block.timestamp < r.startsAt || block.timestamp >= r.endsAt) revert RoundNotOpen();
        uint256 n = projectIds.length;
        if (n == 0 || n != amounts.length || n > MAX_PROJECTS_PER_BACK) revert BadAmounts();

        bytes32 voice = _voiceOf(msg.sender);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            uint256 pid = projectIds[i];
            uint256 amount = amounts[i];
            Project storage p = _project(roundId, pid);
            if (p.status != Status.Approved) revert WrongStatus();
            if (p.voice == voice) revert OwnProject();
            if (amount == 0) revert BadAmounts();

            uint256 before = paidByVoice[roundId][pid][voice];
            if (before != 0 && paidByWallet[roundId][pid][msg.sender] != before) revert WalletMismatch();
            uint256 afterAmt = before + amount;
            if (afterAmt < r.minPerBacker || afterAmt > r.maxPerBacker) revert BadAmounts();

            paidByVoice[roundId][pid][voice] = afterAmt;
            paidByWallet[roundId][pid][msg.sender] = afterAmt;
            p.raised += amount;
            p.sumSqrt = p.sumSqrt + _sqrt(afterAmt) - _sqrt(before);
            if (before == 0) {
                p.backers += 1;
                projectsBackedBy[roundId][voice] += 1;
            }
            total += amount;
            emit Backed(roundId, pid, voice, msg.sender, amount);
        }
        if (total != msg.value) revert BadAmounts();
    }

    /// @notice Add to a round's matching pool. Anyone may do this (no Agent ID needed) until the round ends.
    function topUpPool(uint256 roundId) external payable {
        Round storage r = _round(roundId);
        if (r.cancelled || r.finalised) revert RoundIsFinal();
        if (block.timestamp >= r.endsAt) revert RoundEnded();
        if (msg.value == 0) revert BadAmounts();
        r.pool += msg.value;
        poolFundedBy[roundId][msg.sender] += msg.value;
        emit PoolToppedUp(roundId, msg.sender, msg.value);
    }

    // ============================================================== settlement

    /// @notice Fix each project's share of the matching pool. Anyone can call it, from 24 hours after the round ends.
    ///         Projects need at least five distinct Agent IDs backing them to earn matching. No project gets more than
    ///         the round's cap; what the cap frees is shared among the others, and anything left goes back to the
    ///         pool's funders.
    function finalise(uint256 roundId) external {
        Round storage r = _round(roundId);
        if (r.cancelled || r.finalised) revert RoundIsFinal();
        if (block.timestamp < uint256(r.endsAt) + REVIEW_PERIOD) revert ReviewNotOver();

        uint256[] storage ids = _approvedIds[roundId];
        uint256 n = ids.length;
        uint256[] memory w = new uint256[](n);
        uint256[] memory share = new uint256[](n);
        bool[] memory done = new bool[](n);
        Project[] storage ps = _projects[roundId];

        for (uint256 i; i < n; ++i) {
            Project storage p = ps[ids[i]];
            if (p.status == Status.Approved && p.backers >= MIN_BACKERS_FOR_MATCH) {
                uint256 sq = p.sumSqrt * p.sumSqrt;
                w[i] = sq > p.raised ? sq - p.raised : 0;
            }
            if (w[i] == 0) done[i] = true;
        }

        uint256 cap = (r.pool * r.capBps) / BPS;
        uint256 remaining = r.pool;
        // Water-filling: give each open project its weighted share of what is left; any project above the cap is
        // pinned at the cap and the rest is shared again. At most n passes.
        for (uint256 pass; pass <= n; ++pass) {
            uint256 wSum;
            for (uint256 i; i < n; ++i) {
                if (!done[i]) wSum += w[i];
            }
            if (wSum == 0 || remaining == 0) break;
            bool pinned;
            for (uint256 i; i < n; ++i) {
                if (!done[i] && (remaining * w[i]) / wSum >= cap) {
                    share[i] = cap;
                    done[i] = true;
                    remaining -= cap;
                    pinned = true;
                }
            }
            if (!pinned) {
                uint256 given;
                for (uint256 i; i < n; ++i) {
                    if (!done[i]) {
                        share[i] = (remaining * w[i]) / wSum;
                        given += share[i];
                    }
                }
                remaining -= given;
                break;
            }
        }

        uint256 matchedTotal;
        for (uint256 i; i < n; ++i) {
            if (share[i] != 0) {
                ps[ids[i]].matched = share[i];
                matchedTotal += share[i];
            }
        }
        r.matchedTotal = matchedTotal;
        r.finalised = true;
        emit RoundFinalised(roundId, matchedTotal, r.pool - matchedTotal);
    }

    /// @notice Project wallet collects its direct backing plus its matching share, once, after finalise.
    function claim(uint256 roundId, uint256 projectId) external nonReentrant {
        Round storage r = _round(roundId);
        if (!r.finalised) revert NotFinalised();
        Project storage p = _project(roundId, projectId);
        if (msg.sender != p.wallet) revert NotProjectWallet();
        if (p.status != Status.Approved) revert WrongStatus();
        if (p.claimed) revert AlreadyClaimed();
        p.claimed = true;
        uint256 amount = p.raised + p.matched;
        emit Claimed(roundId, projectId, msg.sender, amount);
        _send(msg.sender, amount);
    }

    /// @notice Take back what you paid to a project that was delisted, or to any project in a cancelled round.
    function refund(uint256 roundId, uint256 projectId) external nonReentrant {
        Round storage r = _round(roundId);
        Project storage p = _project(roundId, projectId);
        if (!r.cancelled && p.status != Status.Delisted) revert NothingToRefund();
        uint256 amount = paidByWallet[roundId][projectId][msg.sender];
        if (amount == 0) revert NothingToRefund();
        paidByWallet[roundId][projectId][msg.sender] = 0;
        emit Refunded(roundId, projectId, msg.sender, amount);
        _send(msg.sender, amount);
    }

    /// @notice Pool funders take back their share of matching money that was not assigned (after finalise), or all
    ///         of it (after cancel).
    function withdrawPool(uint256 roundId) external nonReentrant {
        Round storage r = _round(roundId);
        if (!r.finalised && !r.cancelled) revert NotFinalised();
        uint256 funded = poolFundedBy[roundId][msg.sender];
        if (funded == 0 || poolWithdrawn[roundId][msg.sender]) revert NothingToWithdraw();
        uint256 unused = r.cancelled ? r.pool : r.pool - r.matchedTotal;
        uint256 amount = (funded * unused) / r.pool;
        poolWithdrawn[roundId][msg.sender] = true;
        if (amount == 0) revert NothingToWithdraw();
        emit PoolWithdrawn(roundId, msg.sender, amount);
        _send(msg.sender, amount);
    }

    // =================================================================== views

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return _round(roundId);
    }

    function projectCount(uint256 roundId) external view returns (uint256) {
        return _projects[roundId].length;
    }

    function getProject(uint256 roundId, uint256 projectId) external view returns (Project memory) {
        return _project(roundId, projectId);
    }

    function approvedProjectIds(uint256 roundId) external view returns (uint256[] memory) {
        return _approvedIds[roundId];
    }

    /// @notice The quadratic weight a project has right now (zero below five backers).
    function weightOf(uint256 roundId, uint256 projectId) external view returns (uint256) {
        Project storage p = _project(roundId, projectId);
        if (p.status != Status.Approved || p.backers < MIN_BACKERS_FOR_MATCH) return 0;
        uint256 sq = p.sumSqrt * p.sumSqrt;
        return sq > p.raised ? sq - p.raised : 0;
    }

    /// @notice A building block for other Agent ID apps: has this project been backed by at least `n` Agent IDs?
    function backedByAtLeast(uint256 roundId, uint256 projectId, uint256 n) external view returns (bool) {
        return _project(roundId, projectId).backers >= n;
    }

    // ================================================================ internal

    function _round(uint256 roundId) private view returns (Round storage) {
        if (roundId >= _rounds.length) revert NoSuchRound();
        return _rounds[roundId];
    }

    function _project(uint256 roundId, uint256 projectId) private view returns (Project storage) {
        if (projectId >= _projects[roundId].length) revert NoSuchProject();
        return _projects[roundId][projectId];
    }

    function _steward(uint256 roundId) private view returns (Round storage r) {
        r = _round(roundId);
        if (msg.sender != r.steward) revert NotSteward();
        if (r.finalised || r.cancelled) revert RoundIsFinal();
    }

    function _text(string calldata s, uint256 max) private pure {
        uint256 len = bytes(s).length;
        if (len == 0 || len > max) revert BadText();
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Integer square root (floor), Babylonian method.
    function _sqrt(uint256 x) private pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = x / 2 + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }
}
