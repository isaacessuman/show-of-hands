// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OneVoice, IAgentID} from "./lib/OneVoice.sol";
import {IERC8004Identity} from "./Attestor.sol";
import {IERC8004ReputationFull} from "./lib/IERC8004Full.sol";
import {LiveScore} from "./lib/LiveScore.sol";
import {CrowdScoreV2} from "./CrowdScoreV2.sol";
import {IPriceFeed} from "./Predictions.sol";

/// @title Show of Hands — Predictions v2 (questions the chain answers by itself, and can never get stuck)
/// @notice "Will BNB/USD be above $X at time T?" Every Agent ID gets one vote (Yes / No). Voting closes at least an
///         hour before T. After T anyone may settle the question with the EARLIEST Chainlink price at or after T.
///         The contract checks that claim against the round's own phase and its neighbours (Chainlink starts a new
///         "phase" when it swaps the aggregator behind a feed), so nobody can pick a friendlier price.
///         Changes from v1 (0x77a2…6c8a):
///           - a question can be settled however late the feed updates and across a phase change;
///           - a question nobody can settle 30 days after T becomes Void (it counts for no one);
///           - each voice's accuracy is ONE live lifetime ERC-8004 entry (tag "prediction-accuracy"), built from that
///             voice's own answers in order, so it cannot be inflated by batching and one slow question of
///             somebody else's never holds it back.
/// @dev    No owner, no admin, no upgrade path, no payable function. Holds no money.
contract PredictionsV2 is OneVoice, LiveScore {
    uint256 public constant ASSETS = 3; // 0 = BNB, 1 = BTC, 2 = ETH (all quoted in USD, 8 decimals)
    uint256 public constant MIN_VOTING = 1 hours; // shortest voting window
    uint256 public constant MIN_GAP = 1 hours; // voting must close at least this long before the check time
    uint256 public constant MAX_AHEAD = 30 days; // furthest check time from creation
    uint256 public constant VOID_AFTER = 30 days; // a question still unsettled this long after T may be voided
    uint256 public constant MAX_SCAN = 100; // most answers one attest call may score

    string public constant TAG_ACCURACY = "prediction-accuracy";
    string public constant TAG_SOURCE = "showofhands";
    string public constant ENDPOINT = "https://showofhands.io/#/predict";

    IPriceFeed[ASSETS] public FEEDS;
    CrowdScoreV2 public immutable CROWD_SCORE;

    enum Outcome {
        Pending,
        Above,
        NotAbove,
        Void
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
    /// @notice voice => the prediction ids it answered, in order.
    mapping(bytes32 voice => uint256[]) private _answers;
    /// @notice voice => how many of its answers have been scored.
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
    event Voided(uint256 indexed id);
    event Attested(bytes32 indexed voice, uint256 from, uint256 to, uint32 counted, uint32 correct);

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
    error EarlierRoundExists();
    error NothingToAttest();

    constructor(
        IAgentID registry,
        IPriceFeed[ASSETS] memory feeds,
        CrowdScoreV2 crowdScore,
        IERC8004Identity identity,
        IERC8004ReputationFull reputation
    ) OneVoice(registry) LiveScore(identity, reputation) {
        for (uint256 i; i < ASSETS; ++i) {
            if (address(feeds[i]).code.length == 0 || feeds[i].decimals() != 8) revert BadAsset();
            FEEDS[i] = feeds[i];
        }
        CROWD_SCORE = crowdScore;
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
        _answers[voice].push(id);
        if (above) ++p.yes;
        else ++p.no;
        emit Voted(id, voice, msg.sender, above);
    }

    /// @notice Anyone may settle once the check time has passed, with `roundId` = the earliest Chainlink round
    ///         updated at or after `checkAt`. `prevHint` and `nextHint` prove that the phases just before and after
    ///         `roundId`'s phase have no earlier such round; `settleArgs` computes all three.
    ///         A hint is a round id in that phase: the last round updated before `checkAt`, or aggregator round 0
    ///         if the phase has none. It is ignored when that phase does not exist.
    function settle(uint256 id, uint80 roundId, uint80 prevHint, uint80 nextHint) external {
        if (id >= _preds.length) revert NoSuchPrediction();
        Prediction storage p = _preds[id];
        if (block.timestamp < p.checkAt) revert TooEarly();
        if (p.outcome != Outcome.Pending) revert AlreadySettled();

        IPriceFeed feed = FEEDS[p.asset];
        uint256 t = p.checkAt;
        uint64 agg = uint64(roundId);
        uint16 phase = uint16(roundId >> 64);
        if (agg == 0 || phase == 0 || roundId >> 80 != 0) revert BadRound();
        (bool ok, int256 price, uint256 tR) = _round(feed, roundId);
        if (!ok || price <= 0 || tR < t) revert BadRound();
        // 1. It is the first round at/after T inside its own phase.
        if (agg > 1) {
            (bool okPrev,, uint256 tPrev) = _round(feed, roundId - 1);
            if (!okPrev || tPrev == 0 || tPrev >= t) revert BadRound();
        }
        // 2. The previous phase has no round in [T, tR).
        //    On a tie the older phase wins, so exactly one round is ever valid.
        if (phase > 1) _checkNeighbour(feed, phase - 1, prevHint, t, tR, true);
        // 3. The next phase (if Chainlink has started one) has no round in [T, tR).
        (uint80 latest,,,,) = feed.latestRoundData();
        if (uint16(latest >> 64) > phase) _checkNeighbour(feed, phase + 1, nextHint, t, tR, false);

        bool above = price > p.strike;
        p.outcome = above ? Outcome.Above : Outcome.NotAbove;
        p.settledPrice = price;
        p.settledRound = roundId;
        emit Settled(id, roundId, price, above);
    }

    /// @notice If a question still cannot be settled VOID_AFTER its check time (the feed stopped), anyone may void
    ///         it. A void question counts for no one.
    function voidPrediction(uint256 id) external {
        if (id >= _preds.length) revert NoSuchPrediction();
        Prediction storage p = _preds[id];
        if (p.outcome != Outcome.Pending) revert AlreadySettled();
        if (block.timestamp <= uint256(p.checkAt) + VOID_AFTER) revert TooEarly();
        p.outcome = Outcome.Void;
        emit Voided(id);
    }

    /// @notice Anyone may bring a voice's lifetime accuracy up to date: scores its answers in order from where the
    ///         last call stopped (up to MAX_SCAN, stopping at the first unsettled one; void ones are skipped), then
    ///         rewrites its one live ERC-8004 entry, sent to the agent the voice linked in CrowdScoreV2.
    function attest(bytes32 voice) external {
        (uint256 from, uint256 to, uint32 counted, uint32 correct) = preview(voice);
        if (to == from) revert NothingToAttest();
        next[voice] = to;
        emit Attested(voice, from, to, counted, correct);
        if (counted == 0) return;
        Score storage s = scoreOf[voice];
        s.counted += counted;
        s.hits += correct;
        _publish(voice);
    }

    // ------------------------------------------------------------------ views

    /// @notice What `attest(voice)` would score now: the voice's answers [from, to) (positions in `answersOf`).
    function preview(bytes32 voice) public view returns (uint256 from, uint256 to, uint32 counted, uint32 correct) {
        uint256[] storage a = _answers[voice];
        from = next[voice];
        uint256 end = a.length;
        if (end > from + MAX_SCAN) end = from + MAX_SCAN;
        for (to = from; to < end; ++to) {
            uint256 id = a[to];
            Outcome o = _preds[id].outcome;
            if (o == Outcome.Pending) break;
            if (o == Outcome.Void) continue;
            ++counted;
            if ((choiceOf[id][voice] == 1) == (o == Outcome.Above)) ++correct;
        }
    }

    function answersOf(bytes32 voice) external view returns (uint256[] memory) {
        return _answers[voice];
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

    /// @notice Helper for settlers (call off-chain): the arguments `settle` needs for a check time, found by searching
    ///         the current phase and the two before it. roundId = 0 means no round at/after `checkAt` exists yet.
    function settleArgs(uint8 asset, uint64 checkAt)
        external
        view
        returns (uint80 roundId, uint80 prevHint, uint80 nextHint)
    {
        if (asset >= ASSETS) revert BadAsset();
        IPriceFeed feed = FEEDS[asset];
        (uint80 latest,,,,) = feed.latestRoundData();
        uint16 cur = uint16(latest >> 64);
        uint256 bestT = type(uint256).max;
        uint16 bestPhase;
        uint64[3] memory lastBefore; // per phase cur, cur-1, cur-2
        for (uint16 k; k < 3 && k < cur; ++k) {
            uint16 ph = cur - k;
            uint64 n = k == 0 ? uint64(latest) : _lastRound(feed, ph);
            (uint64 lb, uint256 tFirst) = _firstAtOrAfter(feed, ph, n, checkAt);
            lastBefore[k] = lb;
            if (lb < n && tFirst <= bestT) { // on a tie the older phase wins, as in settle
                bestT = tFirst;
                bestPhase = ph;
            }
        }
        if (bestPhase == 0) return (0, 0, 0);
        uint16 kb = cur - bestPhase;
        roundId = (uint80(bestPhase) << 64) | (lastBefore[kb] + 1);
        if (bestPhase > 1) {
            uint64 lbPrev = kb + 1 < 3 ? lastBefore[kb + 1] : _lastBeforeIn(feed, bestPhase - 1, checkAt);
            prevHint = (uint80(bestPhase - 1) << 64) | lbPrev;
        }
        if (bestPhase < cur) nextHint = (uint80(bestPhase + 1) << 64) | lastBefore[kb - 1];
    }

    // ------------------------------------------------------------------ internals

    /// @dev Phase `ph` has no round updated in [t, tR). `hint` must be in phase `ph`: aggregator round 0 claims the
    ///      phase has no round before t; otherwise the hint round must be before t. Either way the round after the
    ///      hint must be missing or not earlier than tR. A phase with no rounds at all passes with any hint.
    function _checkNeighbour(IPriceFeed feed, uint16 ph, uint80 hint, uint256 t, uint256 tR, bool older)
        private
        view
    {
        if (uint16(hint >> 64) != ph || hint >> 80 != 0) revert BadRound();
        uint64 h = uint64(hint);
        if (h > 0) {
            (bool ok,, uint256 tH) = _round(feed, hint);
            if (!ok || tH == 0 || tH >= t) revert BadRound();
        }
        (bool okN,, uint256 tN) = _round(feed, hint + 1);
        if (okN && (tN < tR || (older && tN == tR))) revert EarlierRoundExists();
    }

    /// @dev In phase `ph` with rounds 1..n: the last round before t (0 if none) and the time of the round after it.
    function _firstAtOrAfter(IPriceFeed feed, uint16 ph, uint64 n, uint256 t)
        private
        view
        returns (uint64 lastBefore, uint256 tFirst)
    {
        if (n == 0) return (0, 0);
        uint80 base = uint80(ph) << 64;
        (, , uint256 tn) = _round(feed, base | n);
        if (tn < t) return (n, 0);
        uint64 lo = 0; // round lo is before t (0 = virtual)
        uint64 hi = n; // round hi is at/after t
        while (hi - lo > 1) {
            uint64 mid = lo + (hi - lo) / 2;
            (bool ok,, uint256 tm) = _round(feed, base | mid);
            if (ok && tm >= t) hi = mid;
            else lo = mid;
        }
        (, , tFirst) = _round(feed, base | hi);
        return (lo, tFirst);
    }

    function _lastBeforeIn(IPriceFeed feed, uint16 ph, uint256 t) private view returns (uint64 lb) {
        (lb,) = _firstAtOrAfter(feed, ph, _lastRound(feed, ph), t);
    }

    /// @dev Highest existing aggregator round in a past phase (rounds are 1..n with no gaps), 0 if none.
    function _lastRound(IPriceFeed feed, uint16 ph) private view returns (uint64) {
        uint80 base = uint80(ph) << 64;
        (bool ok1,,) = _round(feed, base | 1);
        if (!ok1) return 0;
        uint64 lo = 1;
        uint64 hi = 2;
        while (true) {
            (bool ok,,) = _round(feed, base | hi);
            if (!ok) break;
            lo = hi;
            if (hi > type(uint64).max / 2) return hi;
            hi *= 2;
        }
        while (hi - lo > 1) {
            uint64 mid = lo + (hi - lo) / 2;
            (bool ok,,) = _round(feed, base | mid);
            if (ok) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    function _round(IPriceFeed feed, uint80 roundId) private view returns (bool ok, int256 price, uint256 updatedAt) {
        try feed.getRoundData(roundId) returns (uint80, int256 a, uint256, uint256 u, uint80) {
            return (u != 0, a, u);
        } catch {
            return (false, 0, 0);
        }
    }

    function _linkOf(bytes32 voice) internal view override returns (uint256 agentId, address owner) {
        return CROWD_SCORE.links(voice);
    }

    function _tag() internal pure override returns (string memory) {
        return TAG_ACCURACY;
    }

    function _source() internal pure override returns (string memory) {
        return TAG_SOURCE;
    }

    function _endpoint() internal pure override returns (string memory) {
        return ENDPOINT;
    }
}
