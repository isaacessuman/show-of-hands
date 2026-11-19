// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OneVoice, IAgentID} from "./lib/OneVoice.sol";
import {IERC8004Identity, IERC8004Reputation} from "./Attestor.sol";
import {CrowdScore} from "./CrowdScore.sol";

/// @notice The read-only part of a Chainlink price feed (EACAggregatorProxy).
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title Show of Hands — Predictions (questions the chain answers by itself)
/// @notice "Will BNB/USD be above $X at time T?" Every Agent ID gets one vote (Yes / No). Voting closes at least an
///         hour before T. After T anyone may settle the question with the FIRST Chainlink price at or after T; the
///         contract checks that the round given really is that first round, so nobody can pick a friendlier price.
///         Questions have a fixed form (asset, strike, times): there is no free text to spam or to inject.
///         Each voice's accuracy can be written to the ERC-8004 Reputation Registry under tag "prediction-accuracy",
///         using the ERC-8004 agent that voice linked in CrowdScore.
/// @dev    No owner, no admin, no upgrade path, no payable function. Holds no money.
contract Predictions is OneVoice {
    uint256 public constant ASSETS = 3; // 0 = BNB, 1 = BTC, 2 = ETH (all quoted in USD, 8 decimals)
    uint256 public constant MIN_VOTING = 1 hours; // shortest voting window
    uint256 public constant MIN_GAP = 1 hours; // voting must close at least this long before the check time
    uint256 public constant MAX_AHEAD = 30 days; // furthest check time from creation
    uint256 public constant MAX_ROUND_DELAY = 1 days; // a settling round this late after T is refused
    uint256 public constant MAX_SCAN = 100; // most predictions one attest call may scan

    string public constant TAG_ACCURACY = "prediction-accuracy";
    string public constant TAG_SOURCE = "showofhands";
    string public constant ENDPOINT = "https://showofhands.io/#/predict";

    IPriceFeed[ASSETS] public FEEDS;
    CrowdScore public immutable CROWD_SCORE;
    IERC8004Identity public immutable IDENTITY;
    IERC8004Reputation public immutable REPUTATION;

    enum Outcome {
        Pending,
        Above,
        NotAbove
    }

    struct Prediction {
        bytes32 creatorVoice;
        address creator;
        uint8 asset;
        Outcome outcome;
        uint64 createdAt;
        uint64 votingEndsAt;
        uint64 checkAt;
        int256 strike; // in feed units (USD with 8 decimals)
        int256 settledPrice;
        uint80 settledRound;
        uint32 yes;
        uint32 no;
    }

    Prediction[] private _preds;
    /// @notice id => voice => 1 for Yes (above), 2 for No, 0 = did not vote.
    mapping(uint256 id => mapping(bytes32 voice => uint8)) public choiceOf;
    /// @notice voice => (latest prediction id + 1). One prediction with open voting per voice at a time.
    mapping(bytes32 voice => uint256) public latestOf;
    /// @notice voice => first prediction id not yet attested.
    mapping(bytes32 voice => uint256) public next;

    event Created(
        uint256 indexed id,
        bytes32 indexed voice,
        address indexed creator,
        uint8 asset,
        int256 strike,
        uint64 votingEndsAt,
        uint64 checkAt
    );
    event Voted(uint256 indexed id, bytes32 indexed voice, address indexed voter, bool above);
    event Settled(uint256 indexed id, uint80 roundId, int256 price, bool above);
    event Attested(
        bytes32 indexed voice,
        uint256 indexed agentId,
        uint256 from,
        uint256 to,
        uint32 counted,
        uint32 correct,
        bytes32 hash
    );

    error BadAsset();
    error BadStrike();
    error BadTimes();
    error OpenPredictionExists();
    error NoSuchPrediction();
    error VotingClosed();
    error AlreadyVoted();
    error TooEarly();
    error AlreadySettled();
    error BadRound();
    error RoundTooLate();
    error NotSettled(uint256 id);
    error EmptyRange();
    error RangeTooLong();
    error NotLinked();
    error OwnerChanged();

    constructor(
        IAgentID registry,
        IPriceFeed[ASSETS] memory feeds,
        CrowdScore crowdScore,
        IERC8004Identity identity,
        IERC8004Reputation reputation
    ) OneVoice(registry) {
        for (uint256 i; i < ASSETS; ++i) {
            if (address(feeds[i]).code.length == 0 || feeds[i].decimals() != 8) revert BadAsset();
            FEEDS[i] = feeds[i];
        }
        CROWD_SCORE = crowdScore;
        IDENTITY = identity;
        REPUTATION = reputation;
    }

    // ------------------------------------------------------------------ actions

    /// @notice Ask "Will <asset>/USD be above `strike` at `checkAt`?" Sends no BNB.
    function create(uint8 asset, int256 strike, uint64 votingEndsAt, uint64 checkAt) external returns (uint256 id) {
        if (asset >= ASSETS) revert BadAsset();
        if (strike <= 0) revert BadStrike();
        if (
            votingEndsAt < block.timestamp + MIN_VOTING || uint256(checkAt) < uint256(votingEndsAt) + MIN_GAP
                || checkAt > block.timestamp + MAX_AHEAD
        ) revert BadTimes();

        bytes32 voice = _voiceOf(msg.sender);
        uint256 prev = latestOf[voice];
        if (prev != 0 && block.timestamp < _preds[prev - 1].votingEndsAt) revert OpenPredictionExists();

        id = _preds.length;
        _preds.push(
            Prediction({
                creatorVoice: voice,
                creator: msg.sender,
                asset: asset,
                outcome: Outcome.Pending,
                createdAt: uint64(block.timestamp),
                votingEndsAt: votingEndsAt,
                checkAt: checkAt,
                strike: strike,
                settledPrice: 0,
                settledRound: 0,
                yes: 0,
                no: 0
            })
        );
        latestOf[voice] = id + 1;
        emit Created(id, voice, msg.sender, asset, strike, votingEndsAt, checkAt);
    }

    /// @notice Cast this Agent ID's one vote: true = "Yes, above", false = "No". Sends no BNB.
    function vote(uint256 id, bool above) external {
        if (id >= _preds.length) revert NoSuchPrediction();
        Prediction storage p = _preds[id];
        if (block.timestamp >= p.votingEndsAt) revert VotingClosed();
        bytes32 voice = _voiceOf(msg.sender);
        if (choiceOf[id][voice] != 0) revert AlreadyVoted();
        choiceOf[id][voice] = above ? 1 : 2;
        if (above) ++p.yes;
        else ++p.no;
        emit Voted(id, voice, msg.sender, above);
    }

    /// @notice Anyone may settle once the check time has passed. `roundId` must be the FIRST round of the asset's
    ///         Chainlink feed updated at or after `checkAt`; `firstRoundAfter` finds it.
    function settle(uint256 id, uint80 roundId) external {
        if (id >= _preds.length) revert NoSuchPrediction();
        Prediction storage p = _preds[id];
        if (block.timestamp < p.checkAt) revert TooEarly();
        if (p.outcome != Outcome.Pending) revert AlreadySettled();

        IPriceFeed feed = FEEDS[p.asset];
        // Chainlink proxy round ids are (phase << 64) | aggregatorRound. The round before must be in the same
        // phase, so a round that starts a phase cannot be checked and is refused.
        if (uint64(roundId) <= 1) revert BadRound();
        (bool ok, int256 price, uint256 updatedAt) = _round(feed, roundId);
        if (!ok || price <= 0 || updatedAt < p.checkAt) revert BadRound();
        (bool okPrev,, uint256 prevUpdatedAt) = _round(feed, roundId - 1);
        if (!okPrev || prevUpdatedAt == 0 || prevUpdatedAt >= p.checkAt) revert BadRound();
        if (updatedAt > uint256(p.checkAt) + MAX_ROUND_DELAY) revert RoundTooLate();

        bool above = price > p.strike;
        p.outcome = above ? Outcome.Above : Outcome.NotAbove;
        p.settledPrice = price;
        p.settledRound = roundId;
        emit Settled(id, roundId, price, above);
    }

    /// @notice Anyone may write a voice's accuracy over predictions [next[voice], toId) to ERC-8004. Every prediction
    ///         in the range must be settled. Ranges are contiguous from the last attestation, so none can be skipped.
    function attest(bytes32 voice, uint256 toId) external {
        (uint256 from, uint256 to, uint32 counted, uint32 correct) = preview(voice, toId);
        next[voice] = to;

        (uint256 agentId, address owner) = CROWD_SCORE.links(voice);
        bytes32 hash = keccak256(abi.encode(block.chainid, address(this), voice, from, to, counted, correct));
        emit Attested(voice, agentId, from, to, counted, correct, hash);
        if (counted == 0) return;

        if (owner == address(0)) revert NotLinked();
        if (IDENTITY.ownerOf(agentId) != owner) revert OwnerChanged();
        REPUTATION.giveFeedback(
            agentId,
            int128(uint128(uint256(correct) * 100 / counted)),
            0,
            TAG_ACCURACY,
            TAG_SOURCE,
            ENDPOINT,
            "",
            hash
        );
    }

    // ------------------------------------------------------------------ views

    /// @notice What `attest(voice, toId)` would count right now. Reverts for the same reasons.
    function preview(bytes32 voice, uint256 toId)
        public
        view
        returns (uint256 from, uint256 to, uint32 counted, uint32 correct)
    {
        from = next[voice];
        to = toId;
        if (to <= from) revert EmptyRange();
        if (to - from > MAX_SCAN) revert RangeTooLong();
        if (to > _preds.length) revert NoSuchPrediction();
        for (uint256 id = from; id < to; ++id) {
            Outcome o = _preds[id].outcome;
            if (o == Outcome.Pending) revert NotSettled(id);
            uint8 c = choiceOf[id][voice];
            if (c == 0) continue;
            ++counted;
            if ((c == 1) == (o == Outcome.Above)) ++correct;
        }
    }

    function count() external view returns (uint256) {
        return _preds.length;
    }

    function getPrediction(uint256 id) external view returns (Prediction memory) {
        if (id >= _preds.length) revert NoSuchPrediction();
        return _preds[id];
    }

    /// @notice The latest price of an asset, for display.
    function priceNow(uint8 asset) external view returns (int256 price, uint256 updatedAt) {
        if (asset >= ASSETS) revert BadAsset();
        (, price,, updatedAt,) = FEEDS[asset].latestRoundData();
    }

    /// @notice Helper for settlers: binary-searches the asset's current Chainlink phase for the first round updated at
    ///         or after `checkAt`. Returns 0 if the latest round is still before `checkAt` or the answer lies in an
    ///         earlier phase. Rounds within one phase are numbered in time order.
    function firstRoundAfter(uint8 asset, uint64 checkAt) external view returns (uint80) {
        if (asset >= ASSETS) revert BadAsset();
        IPriceFeed feed = FEEDS[asset];
        (uint80 latest,,, uint256 t,) = feed.latestRoundData();
        if (t < checkAt) return 0;
        uint80 phase = latest & ~uint80(type(uint64).max);
        uint64 lo = 1;
        uint64 hi = uint64(latest);
        (bool okLo,, uint256 tLo) = _round(feed, phase | lo);
        if (okLo && tLo >= checkAt) return 0; // the first round of this phase is already after T
        // invariant: round lo is before checkAt (or missing), round hi is at/after checkAt
        while (hi - lo > 1) {
            uint64 mid = lo + (hi - lo) / 2;
            (bool ok,, uint256 tm) = _round(feed, phase | mid);
            if (ok && tm >= checkAt) hi = mid;
            else lo = mid;
        }
        return phase | hi;
    }

    function _round(IPriceFeed feed, uint80 roundId) private view returns (bool ok, int256 price, uint256 updatedAt) {
        try feed.getRoundData(roundId) returns (uint80, int256 a, uint256, uint256 u, uint80) {
            return (true, a, u);
        } catch {
            return (false, 0, 0);
        }
    }
}
