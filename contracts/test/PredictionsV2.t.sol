// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Polls} from "../src/Polls.sol";
import {CrowdScoreV2} from "../src/CrowdScoreV2.sol";
import {PredictionsV2} from "../src/PredictionsV2.sol";
import {IPriceFeed} from "../src/Predictions.sol";
import {IERC8004Identity} from "../src/Attestor.sol";
import {IERC8004ReputationFull} from "../src/lib/IERC8004Full.sol";
import {IAgentID} from "../src/lib/OneVoice.sol";
import {MockAgentID} from "./mocks/MockAgentID.sol";
import {MockIdentity2, MockReputation2} from "./mocks/MockERC8004.sol";

/// @dev Chainlink proxy double where any phase can keep receiving rounds (an old aggregator that still updates,
///      or a new one that started before the switch). `current` is the phase latestRoundData reads.
contract MockFeedPhases {
    uint16 public current = 1;
    mapping(uint16 => uint64) public n;
    mapping(uint80 => int256) public price;
    mapping(uint80 => uint256) public time;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function pushTo(uint16 ph, int256 p, uint256 t) public returns (uint80 id) {
        id = (uint80(ph) << 64) | ++n[ph];
        price[id] = p;
        time[id] = t;
    }

    function push(int256 p, uint256 t) external returns (uint80) {
        return pushTo(current, p, t);
    }

    function setCurrent(uint16 ph) external {
        current = ph;
    }

    function getRoundData(uint80 r) public view returns (uint80, int256, uint256, uint256, uint80) {
        require(time[r] != 0, "No data present");
        return (r, price[r], time[r], time[r], r);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint80 id = (uint80(current) << 64) | n[current];
        return (id, price[id], time[id], time[id], id);
    }
}

contract PredictionsV2Test is Test {
    MockAgentID reg;
    MockIdentity2 idr;
    MockReputation2 rep;
    Polls polls;
    CrowdScoreV2 cs;
    PredictionsV2 pr;
    MockFeedPhases[3] feeds;
    address[] v;
    bytes32 aliceVoice = keccak256("p0");
    uint256 constant AGENT = 7;
    int256 constant USD = 1e8;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new MockAgentID();
        idr = new MockIdentity2();
        rep = new MockReputation2();
        polls = new Polls(IAgentID(address(reg)));
        cs = new CrowdScoreV2(polls, IERC8004Identity(address(idr)), IERC8004ReputationFull(address(rep)));
        IPriceFeed[3] memory f;
        for (uint256 i; i < 3; ++i) {
            feeds[i] = new MockFeedPhases();
            feeds[i].push(500 * USD, 1_800_000_000 - 10);
            f[i] = IPriceFeed(address(feeds[i]));
        }
        pr = new PredictionsV2(
            IAgentID(address(reg)), f, cs, IERC8004Identity(address(idr)), IERC8004ReputationFull(address(rep))
        );
        for (uint256 i; i < 8; ++i) {
            string memory name = string.concat("p", vm.toString(i));
            address a = makeAddr(name);
            reg.give(a, name);
            v.push(a);
        }
        idr.setOwner(AGENT, v[0]);
    }

    // ------------------------------------------------------------------ helpers

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _create(address who, int256 strike) internal returns (uint256 id, uint64 checkAt) {
        uint64 ends = uint64(_now() + 2 hours);
        checkAt = ends + 1 hours;
        vm.prank(who);
        id = pr.create(0, strike, ends, checkAt);
    }

    function _vote(uint256 id, uint256 voter, bool above) internal {
        vm.prank(v[voter]);
        pr.vote(id, above);
    }

    function _settleWithArgs(uint256 id, uint64 checkAt) internal returns (uint80 r) {
        (uint80 roundId, uint80 ph, uint80 nh) = pr.settleArgs(0, checkAt);
        pr.settle(id, roundId, ph, nh);
        return roundId;
    }

    function _outcome(uint256 id) internal view returns (PredictionsV2.Outcome) {
        return pr.getPrediction(id).outcome;
    }

    // ------------------------------------------------------------------ settle: normal

    function test_settleFirstRoundAfter() public {
        (uint256 id, uint64 T) = _create(v[1], 600 * USD);
        MockFeedPhases f = feeds[0];
        f.push(1 * USD, T - 30);
        uint80 first = f.push(700 * USD, T + 5);
        f.push(1 * USD, T + 60);
        vm.warp(T + 120);
        // a later round is refused
        vm.expectRevert(PredictionsV2.BadRound.selector);
        pr.settle(id, first + 1, 0, 0);
        assertEq(_settleWithArgs(id, T), first);
        assertEq(uint8(_outcome(id)), uint8(PredictionsV2.Outcome.Above));
    }

    /// v1 refused rounds more than a day late, which could leave a question stuck forever.
    function test_lateFeedStillSettles() public {
        (uint256 id, uint64 T) = _create(v[1], 600 * USD);
        feeds[0].push(1 * USD, T - 30);
        uint80 first = feeds[0].push(100 * USD, T + 3 days);
        vm.warp(T + 4 days);
        assertEq(_settleWithArgs(id, T), first);
        assertEq(uint8(_outcome(id)), uint8(PredictionsV2.Outcome.NotAbove));
    }

    function test_tooEarlyAndNoRoundYet() public {
        (uint256 id, uint64 T) = _create(v[1], 600 * USD);
        vm.expectRevert(PredictionsV2.TooEarly.selector);
        pr.settle(id, 1, 0, 0);
        vm.warp(T + 10);
        (uint80 r,,) = pr.settleArgs(0, T);
        assertEq(r, 0);
    }

    // ------------------------------------------------------------------ settle: phase changes

    /// v1 refused the first round of a phase, so a question could get stuck across an aggregator swap.
    function test_firstRoundOfNewPhase() public {
        (uint256 id, uint64 T) = _create(v[1], 600 * USD);
        MockFeedPhases f = feeds[0];
        f.push(1 * USD, T - 30); // phase 1, before T
        f.setCurrent(2);
        uint80 first = f.push(650 * USD, T + 20); // phase 2 round 1
        vm.warp(T + 120);
        assertEq(first, (uint80(2) << 64) | 1);
        assertEq(_settleWithArgs(id, T), first);
        assertEq(pr.getPrediction(id).settledPrice, 650 * USD);
    }

    /// The old aggregator kept updating after the swap and had an earlier price after T: only that one is valid.
    function test_earliestAcrossPhasesWins() public {
        (uint256 id, uint64 T) = _create(v[1], 600 * USD);
        MockFeedPhases f = feeds[0];
        f.push(1 * USD, T - 30);
        uint80 oldFirst = f.pushTo(1, 610 * USD, T + 10); // phase 1, earlier
        f.setCurrent(2);
        f.push(1 * USD, T - 50); // new aggregator was already running
        uint80 newFirst = f.push(590 * USD, T + 40); // phase 2, later
        vm.warp(T + 120);

        uint80 p1Last = (uint80(1) << 64) | 1;
        uint80 p2Last = (uint80(2) << 64) | 1;
        // phase 2's round is refused: phase 1 has an earlier price after T
        vm.expectRevert(PredictionsV2.EarlierRoundExists.selector);
        pr.settle(id, newFirst, p1Last, 0);
        // phase 1's round needs the next-phase proof and passes
        pr.settle(id, oldFirst, 0, p2Last);
        assertEq(uint8(_outcome(id)), uint8(PredictionsV2.Outcome.Above));
    }

    function test_settleArgsFindsOlderPhase() public {
        (uint256 id, uint64 T) = _create(v[1], 600 * USD);
        MockFeedPhases f = feeds[0];
        f.push(1 * USD, T - 30);
        uint80 oldFirst = f.pushTo(1, 610 * USD, T + 10);
        f.setCurrent(2);
        f.push(1 * USD, T - 50);
        f.push(590 * USD, T + 40);
        vm.warp(T + 120);
        assertEq(_settleWithArgs(id, T), oldFirst);
    }

    function test_badHintsRefused() public {
        (uint256 id, uint64 T) = _create(v[1], 600 * USD);
        MockFeedPhases f = feeds[0];
        f.push(1 * USD, T - 30); // p1 r2
        f.setCurrent(2);
        uint80 first = f.push(650 * USD, T + 20);
        vm.warp(T + 120);
        // hint in the wrong phase
        vm.expectRevert(PredictionsV2.BadRound.selector);
        pr.settle(id, first, (uint80(3) << 64) | 1, 0);
        // hint that is not the last round before T in phase 1 (round 1 is followed by round 2, which is before T
        // but the check is only "next is not earlier than tR": round 2 at T-30 < tR) => refused
        vm.expectRevert(PredictionsV2.EarlierRoundExists.selector);
        pr.settle(id, first, (uint80(1) << 64) | 1, 0);
        // correct hint
        pr.settle(id, first, (uint80(1) << 64) | 2, 0);
    }

    function test_tieGoesToOlderPhase() public {
        (uint256 id, uint64 T) = _create(v[1], 600 * USD);
        MockFeedPhases f = feeds[0];
        f.push(1 * USD, T - 30);
        uint80 oldFirst = f.pushTo(1, 610 * USD, T + 10);
        f.setCurrent(2);
        uint80 newFirst = f.push(590 * USD, T + 10); // same time
        vm.warp(T + 120);
        vm.expectRevert(PredictionsV2.EarlierRoundExists.selector);
        pr.settle(id, newFirst, (uint80(1) << 64) | 1, 0);
        assertEq(_settleWithArgs(id, T), oldFirst);
    }

    // ------------------------------------------------------------------ void

    function test_voidAfter30Days() public {
        (uint256 id, uint64 T) = _create(v[1], 600 * USD);
        _vote(id, 0, true);
        vm.warp(T + 30 days);
        vm.expectRevert(PredictionsV2.TooEarly.selector);
        pr.voidPrediction(id);
        vm.warp(T + 30 days + 1);
        pr.voidPrediction(id);
        assertEq(uint8(_outcome(id)), uint8(PredictionsV2.Outcome.Void));
        vm.expectRevert(PredictionsV2.AlreadySettled.selector);
        pr.settle(id, 1, 0, 0);
    }

    // ------------------------------------------------------------------ attest

    function _settledQuestion(uint256 creator, bool aliceAbove, int256 settlePrice) internal returns (uint256 id) {
        uint64 T;
        (id, T) = _create(v[creator], 600 * USD);
        _vote(id, 0, aliceAbove);
        feeds[0].push(1 * USD, T - 1);
        feeds[0].push(settlePrice, T + 1);
        vm.warp(T + 10);
        _settleWithArgs(id, T);
    }

    function test_lifetimeAccuracyOneLiveEntry() public {
        vm.prank(v[0]);
        cs.link(AGENT);
        _settledQuestion(1, true, 700 * USD); // right
        pr.attest(aliceVoice);
        _settledQuestion(2, true, 500 * USD); // wrong
        pr.attest(aliceVoice);
        _settledQuestion(3, false, 500 * USD); // right
        pr.attest(aliceVoice);
        int128[] memory l = rep.live(AGENT, address(pr));
        assertEq(l.length, 1);
        assertEq(l[0], 66);
        (uint32 c, uint32 h) = pr.scoreOf(aliceVoice);
        assertEq(c, 3);
        assertEq(h, 2);
    }

    /// Someone else's slow question does not hold a voice back: only its own answers are scanned.
    function test_othersPendingQuestionDoesNotBlock() public {
        vm.prank(v[0]);
        cs.link(AGENT);
        (uint256 slow,) = _create(v[4], 600 * USD); // alice does not answer this one
        _vote(slow, 1, true);
        _settledQuestion(1, true, 700 * USD);
        pr.attest(aliceVoice);
        (uint32 c,) = pr.scoreOf(aliceVoice);
        assertEq(c, 1);
    }

    function test_voidSkippedAndPendingStops() public {
        vm.prank(v[0]);
        cs.link(AGENT);
        (uint256 a, uint64 Ta) = _create(v[1], 600 * USD);
        _vote(a, 0, true);
        vm.expectRevert(PredictionsV2.NothingToAttest.selector);
        pr.attest(aliceVoice); // pending
        vm.warp(Ta + 30 days + 1);
        pr.voidPrediction(a);
        _settledQuestion(2, true, 700 * USD);
        pr.attest(aliceVoice);
        (uint32 c, uint32 h) = pr.scoreOf(aliceVoice);
        assertEq(c, 1);
        assertEq(h, 1);
        assertEq(pr.next(aliceVoice), 2);
    }

    function test_usesCrowdScoreLink() public {
        _settledQuestion(1, true, 700 * USD);
        pr.attest(aliceVoice); // not linked yet: score kept, nothing written
        assertEq(rep.getLastIndex(AGENT, address(pr)), 0);
        vm.prank(v[0]);
        cs.link(AGENT);
        pr.publish(aliceVoice);
        assertEq(rep.live(AGENT, address(pr)).length, 1);
    }

    function test_oneOpenQuestionPerVoice() public {
        _create(v[1], 600 * USD);
        uint64 ends = uint64(_now() + 2 hours);
        vm.prank(v[1]);
        vm.expectRevert(PredictionsV2.OpenPredictionExists.selector);
        pr.create(0, 600 * USD, ends, ends + 1 hours);
    }

    function test_oneVotePerVoice() public {
        (uint256 id,) = _create(v[1], 600 * USD);
        _vote(id, 0, true);
        vm.prank(v[0]);
        vm.expectRevert(PredictionsV2.AlreadyVoted.selector);
        pr.vote(id, false);
    }

    // ------------------------------------------------------------------ fuzz: exactly one valid round

    function _tryAll(uint256 id, uint80 r, uint16 ph, uint64[3] memory counts) internal returns (bool any) {
        // every possible hint pair (0..n in each neighbour phase)
        uint16 prevPh = ph - 1;
        uint16 nextPh = ph + 1;
        uint64 pn = prevPh >= 1 ? counts[prevPh] : 0;
        uint64 nn = nextPh <= 2 ? counts[nextPh] : 0;
        for (uint64 a; a <= pn; ++a) {
            for (uint64 b; b <= nn; ++b) {
                uint80 ph1 = prevPh >= 1 ? (uint80(prevPh) << 64) | a : 0;
                uint80 nh1 = nextPh <= 2 ? (uint80(nextPh) << 64) | b : 0;
                uint256 snap = vm.snapshotState();
                try pr.settle(id, r, ph1, nh1) {
                    any = true;
                } catch {}
                vm.revertToState(snap);
                if (any) return true;
            }
        }
    }

    function testFuzz_exactlyOneRoundSettles(uint256 seed) public {
        (uint256 id, uint64 T) = _create(v[1], 600 * USD);
        // feeds[0] already has round 1 of phase 1, before T
        MockFeedPhases g = feeds[0];
        uint64[3] memory counts;
        counts[1] = 1;
        uint256[3] memory lastT;
        lastT[1] = 1_800_000_000 - 10;
        lastT[2] = T - 200;
        uint256 rounds = 2 + seed % 7;
        for (uint256 i; i < rounds; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint16 ph = uint16(1 + seed % 2);
            uint256 t = lastT[ph] + 1 + (seed >> 8) % 120;
            lastT[ph] = t;
            g.pushTo(ph, 500 * USD + int256(seed % 200) * USD, t);
            ++counts[ph];
        }
        if (counts[2] > 0 && (seed >> 100) % 2 == 0) g.setCurrent(2);
        vm.warp(T + 10_000);

        // brute force: the earliest round at/after T across both phases (older phase wins ties)
        uint80 expected;
        uint256 bestT = type(uint256).max;
        for (uint16 ph = 2; ph >= 1; --ph) {
            for (uint64 k = 1; k <= counts[ph]; ++k) {
                uint80 r = (uint80(ph) << 64) | k;
                uint256 t = g.time(r);
                if (t >= T && t <= bestT) {
                    if (t < bestT || ph == 1) expected = r;
                    bestT = t;
                    break;
                }
            }
        }
        // a phase the proxy has not switched to yet is invisible to settle's next-phase check, so only
        // assert when phase 2 is current or empty
        if (g.current() == 1 && counts[2] > 0) return;

        (uint80 got,,) = pr.settleArgs(0, T);
        assertEq(got, expected, "settleArgs");
        for (uint16 ph = 1; ph <= 2; ++ph) {
            for (uint64 k = 1; k <= counts[ph]; ++k) {
                uint80 r = (uint80(ph) << 64) | k;
                bool ok = _tryAll(id, r, ph, counts);
                assertEq(ok, r == expected, "uniqueness");
            }
        }
    }
}
