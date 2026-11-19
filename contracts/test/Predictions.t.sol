// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Polls} from "../src/Polls.sol";
import {CrowdScore} from "../src/CrowdScore.sol";
import {Predictions, IPriceFeed} from "../src/Predictions.sol";
import {IERC8004Identity, IERC8004Reputation} from "../src/Attestor.sol";
import {IAgentID} from "../src/lib/OneVoice.sol";
import {MockAgentID} from "./mocks/MockAgentID.sol";
import {MockIdentity, MockReputation} from "./CrowdScore.t.sol";

/// @dev Chainlink-like proxy: round ids are (phase << 64) | n, n starting at 1. Unknown rounds revert.
contract MockFeed {
    uint16 public phase = 1;
    mapping(uint80 => int256) public price;
    mapping(uint80 => uint256) public time;
    uint80 public latest;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function push(int256 p, uint256 t) external returns (uint80 id) {
        uint64 n = latest == 0 ? 1 : uint64(latest) + 1;
        id = (uint80(phase) << 64) | n;
        price[id] = p;
        time[id] = t;
        latest = id;
    }

    function newPhase() external {
        phase += 1;
        latest = uint80(phase) << 64; // next push is round 1 of the new phase
    }

    function getRoundData(uint80 r) public view returns (uint80, int256, uint256, uint256, uint80) {
        require(time[r] != 0, "No data present");
        return (r, price[r], time[r], time[r], r);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return getRoundData(latest);
    }
}

contract PredictionsTest is Test {
    MockAgentID reg;
    MockIdentity idr;
    MockReputation rep;
    Polls polls;
    CrowdScore cs;
    Predictions pr;
    MockFeed[3] feeds;
    address[] v;
    uint256 constant AGENT = 7;
    int256 constant USD = 1e8;

    function setUp() public {
        vm.warp(1_800_000_000);
        reg = new MockAgentID();
        idr = new MockIdentity();
        rep = new MockReputation();
        polls = new Polls(IAgentID(address(reg)));
        cs = new CrowdScore(polls, IERC8004Identity(address(idr)), IERC8004Reputation(address(rep)));
        IPriceFeed[3] memory f;
        for (uint256 i; i < 3; ++i) {
            feeds[i] = new MockFeed();
            feeds[i].push(500 * USD, block.timestamp - 10);
            f[i] = IPriceFeed(address(feeds[i]));
        }
        pr = new Predictions(
            IAgentID(address(reg)), f, cs, IERC8004Identity(address(idr)), IERC8004Reputation(address(rep))
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

    function _create(address who, uint8 asset, int256 strike) internal returns (uint256 id, uint64 checkAt) {
        uint64 ends = uint64(block.timestamp + 2 hours);
        checkAt = ends + 1 hours;
        vm.prank(who);
        id = pr.create(asset, strike, ends, checkAt);
    }

    function _vote(uint256 id, uint256 voter, bool above) internal {
        vm.prank(v[voter]);
        pr.vote(id, above);
    }

    /// Pushes rounds before and after checkAt and returns the first round at/after it.
    function _pricesAround(uint8 asset, uint64 checkAt, int256 atPrice) internal returns (uint80 first) {
        MockFeed f = feeds[asset];
        f.push(1 * USD, checkAt - 30);
        f.push(2 * USD, checkAt - 1);
        first = f.push(atPrice, checkAt + 5);
        f.push(9999 * USD, checkAt + 60);
    }

    function _settle(uint256 id, uint8 asset, uint64 checkAt, int256 atPrice) internal {
        uint80 r = _pricesAround(asset, checkAt, atPrice);
        vm.warp(checkAt + 120);
        pr.settle(id, r);
    }

    // ------------------------------------------------------------------ create

    function test_createStoresQuestion() public {
        (uint256 id, uint64 checkAt) = _create(v[0], 1, 63_000 * USD);
        Predictions.Prediction memory p = pr.getPrediction(id);
        assertEq(p.asset, 1);
        assertEq(p.strike, 63_000 * USD);
        assertEq(p.checkAt, checkAt);
        assertEq(p.creator, v[0]);
        assertEq(uint8(p.outcome), 0);
        assertEq(pr.count(), 1);
    }

    function test_createRejectsBadInput() public {
        uint64 ends = uint64(block.timestamp + 2 hours);
        vm.startPrank(v[0]);
        vm.expectRevert(Predictions.BadAsset.selector);
        pr.create(3, USD, ends, ends + 1 hours);
        vm.expectRevert(Predictions.BadStrike.selector);
        pr.create(0, 0, ends, ends + 1 hours);
        vm.expectRevert(Predictions.BadTimes.selector); // voting too short
        pr.create(0, USD, uint64(block.timestamp + 30 minutes), ends + 1 hours);
        vm.expectRevert(Predictions.BadTimes.selector); // gap too short
        pr.create(0, USD, ends, ends + 30 minutes);
        vm.expectRevert(Predictions.BadTimes.selector); // too far ahead
        pr.create(0, USD, ends, uint64(block.timestamp + 31 days));
        vm.stopPrank();
        vm.prank(makeAddr("noid"));
        vm.expectRevert();
        pr.create(0, USD, ends, ends + 1 hours);
    }

    function test_oneOpenPredictionPerVoice() public {
        _create(v[0], 0, USD);
        vm.expectRevert(Predictions.OpenPredictionExists.selector);
        _create(v[0], 0, USD);
        vm.warp(block.timestamp + 2 hours);
        _create(v[0], 0, USD); // voting on the first has closed
    }

    // ------------------------------------------------------------------ vote

    function test_voteOncePerVoiceAndCloses() public {
        (uint256 id,) = _create(v[7], 0, USD);
        _vote(id, 0, true);
        _vote(id, 1, false);
        _vote(id, 2, false);
        vm.expectRevert(Predictions.AlreadyVoted.selector);
        _vote(id, 0, false);
        Predictions.Prediction memory p = pr.getPrediction(id);
        assertEq(p.yes, 1);
        assertEq(p.no, 2);
        assertEq(pr.choiceOf(id, keccak256("p0")), 1);
        assertEq(pr.choiceOf(id, keccak256("p1")), 2);
        vm.warp(p.votingEndsAt);
        vm.expectRevert(Predictions.VotingClosed.selector);
        _vote(id, 3, true);
        vm.expectRevert(Predictions.NoSuchPrediction.selector);
        _vote(99, 3, true);
    }

    // ------------------------------------------------------------------ settle

    function test_settleAboveAndNotAbove() public {
        (uint256 a, uint64 ca) = _create(v[0], 0, 600 * USD);
        _settle(a, 0, ca, 601 * USD);
        Predictions.Prediction memory p = pr.getPrediction(a);
        assertEq(uint8(p.outcome), uint8(Predictions.Outcome.Above));
        assertEq(p.settledPrice, 601 * USD);

        (uint256 b, uint64 cb) = _create(v[1], 1, 600 * USD);
        _settle(b, 1, cb, 600 * USD); // equal is not above
        assertEq(uint8(pr.getPrediction(b).outcome), uint8(Predictions.Outcome.NotAbove));
    }

    function test_settleOnlyAcceptsTheFirstRoundAfterT() public {
        (uint256 id, uint64 checkAt) = _create(v[0], 0, 600 * USD);
        uint80 first = _pricesAround(0, checkAt, 601 * USD);
        vm.expectRevert(Predictions.TooEarly.selector);
        pr.settle(id, first);
        vm.warp(checkAt + 120);
        vm.expectRevert(Predictions.BadRound.selector); // a later, friendlier round
        pr.settle(id, first + 1);
        vm.expectRevert(Predictions.BadRound.selector); // a round before T
        pr.settle(id, first - 1);
        vm.expectRevert(Predictions.BadRound.selector); // a round that does not exist
        pr.settle(id, first + 50);
        pr.settle(id, first);
        vm.expectRevert(Predictions.AlreadySettled.selector);
        pr.settle(id, first);
    }

    function test_settleRefusesPhaseStartAndLateRounds() public {
        (uint256 id, uint64 checkAt) = _create(v[0], 2, 600 * USD);
        feeds[2].push(1 * USD, checkAt - 10);
        feeds[2].newPhase();
        uint80 r1 = feeds[2].push(700 * USD, checkAt + 10); // round 1 of a new phase: cannot be proven first
        vm.warp(checkAt + 3 days);
        vm.expectRevert(Predictions.BadRound.selector);
        pr.settle(id, r1);

        (uint256 id2, uint64 c2) = _create(v[1], 0, 600 * USD);
        feeds[0].push(1 * USD, c2 - 10);
        uint80 late = feeds[0].push(700 * USD, c2 + 1 days + 1);
        vm.warp(c2 + 3 days);
        vm.expectRevert(Predictions.RoundTooLate.selector);
        pr.settle(id2, late);
    }

    function test_firstRoundAfterFindsTheRound() public {
        MockFeed f = feeds[0];
        uint256 t0 = block.timestamp;
        uint80 want;
        for (uint256 i; i < 300; ++i) {
            uint80 r = f.push(int256(500 + i) * USD, t0 + i * 7);
            if (want == 0 && t0 + i * 7 >= t0 + 1000) want = r;
        }
        assertEq(pr.firstRoundAfter(0, uint64(t0 + 1000)), want);
        assertEq(pr.firstRoundAfter(0, uint64(t0 + 10_000)), 0); // latest is before T
        assertEq(pr.firstRoundAfter(0, uint64(t0 - 1)), (uint80(1) << 64) | 2); // round 1 is before T
    }

    // ------------------------------------------------------------------ attest

    function test_attestWritesAccuracyToERC8004() public {
        vm.prank(v[0]);
        cs.link(AGENT);
        bytes32 me = keccak256("p0");
        // three predictions: p0 right, wrong, right; one p0 skips
        uint256[] memory ids = new uint256[](4);
        bool[4] memory up = [true, true, false, true];
        bool[4] memory pick = [true, false, false, true];
        for (uint256 i; i < 4; ++i) {
            (uint256 id, uint64 c) = _create(v[4 + i], 0, 600 * USD);
            ids[i] = id;
            if (i != 3) _vote(id, 0, pick[i]);
            _settle(id, 0, c, up[i] ? 700 * USD : 500 * USD);
        }
        (uint256 from, uint256 to, uint32 counted, uint32 correct) = pr.preview(me, 4);
        assertEq(from, 0);
        assertEq(to, 4);
        assertEq(counted, 3);
        assertEq(correct, 2); // #0 right, #1 wrong (said no, went up), #2 right (said no, went down)
        pr.attest(me, 4);
        assertEq(rep.count(), 1);
        MockReputation.Call memory c0 = rep.get(0);
        assertEq(c0.sender, address(pr));
        assertEq(c0.agentId, AGENT);
        assertEq(c0.value, 66);
        assertEq(c0.tag1, "prediction-accuracy");
        assertEq(pr.next(me), 4);
        vm.expectRevert(Predictions.EmptyRange.selector);
        pr.attest(me, 4);
    }

    function test_attestNeedsSettledAndLinked() public {
        bytes32 me = keccak256("p0");
        (uint256 id, uint64 c) = _create(v[5], 0, 600 * USD);
        _vote(id, 0, true);
        vm.expectRevert(abi.encodeWithSelector(Predictions.NotSettled.selector, 0));
        pr.attest(me, 1);
        _settle(id, 0, c, 700 * USD);
        vm.expectRevert(Predictions.NotLinked.selector);
        pr.attest(me, 1);
        vm.prank(v[0]);
        cs.link(AGENT);
        idr.setOwner(AGENT, v[3]);
        vm.expectRevert(Predictions.OwnerChanged.selector);
        pr.attest(me, 1);
    }

    function test_attestWithNothingCountedJustAdvances() public {
        bytes32 me = keccak256("p0");
        (uint256 id, uint64 c) = _create(v[5], 0, 600 * USD);
        _settle(id, 0, c, 700 * USD);
        pr.attest(me, 1); // p0 did not vote: no feedback, no link needed
        assertEq(rep.count(), 0);
        assertEq(pr.next(me), 1);
    }

    function test_constructorRejectsBadFeed() public {
        IPriceFeed[3] memory f = [IPriceFeed(address(feeds[0])), IPriceFeed(address(feeds[1])), IPriceFeed(address(0xdead))];
        vm.expectRevert(Predictions.BadAsset.selector);
        new Predictions(IAgentID(address(reg)), f, cs, IERC8004Identity(address(idr)), IERC8004Reputation(address(rep)));
    }
}
