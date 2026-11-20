// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Polls} from "../src/Polls.sol";
import {CrowdScoreV2} from "../src/CrowdScoreV2.sol";
import {LiveScore} from "../src/lib/LiveScore.sol";
import {IERC8004Identity} from "../src/Attestor.sol";
import {IERC8004ReputationFull} from "../src/lib/IERC8004Full.sol";
import {IAgentID} from "../src/lib/OneVoice.sol";
import {MockAgentID} from "./mocks/MockAgentID.sol";
import {MockIdentity2, MockReputation2} from "./mocks/MockERC8004.sol";

contract CrowdScoreV2Test is Test {
    uint8 constant SKIP = type(uint8).max;

    MockAgentID reg;
    MockIdentity2 idr;
    MockReputation2 rep;
    Polls polls;
    CrowdScoreV2 cs;

    address[] v; // v[0] is the voter under test
    bytes32 aliceVoice = keccak256("voter0");
    bytes32 bobVoice = keccak256("voter1");
    uint256 constant AGENT = 42;
    uint256 creatorIdx = 6;

    function setUp() public {
        reg = new MockAgentID();
        polls = new Polls(IAgentID(address(reg)));
        idr = new MockIdentity2();
        rep = new MockReputation2();
        cs = new CrowdScoreV2(polls, IERC8004Identity(address(idr)), IERC8004ReputationFull(address(rep)));
        for (uint256 i; i < 40; ++i) {
            string memory name = string.concat("voter", vm.toString(i));
            address a = makeAddr(name);
            reg.give(a, name);
            v.push(a);
        }
        idr.setOwner(AGENT, v[0]);
        idr.setOwner(AGENT + 1, v[0]);
        idr.setOwner(AGENT + 2, v[1]);
    }

    // ----------------------------------------------------------------- helpers

    function _poll(uint256 nOpts, uint8[] memory choices, uint64 duration) internal returns (uint256 id) {
        string[] memory o = new string[](nOpts);
        for (uint256 i; i < nOpts; ++i) {
            o[i] = string.concat("opt", vm.toString(i));
        }
        vm.prank(v[creatorIdx++]);
        id = polls.createPoll("q?", o, uint64(vm.getBlockTimestamp() + duration));
        for (uint256 i; i < choices.length; ++i) {
            if (choices[i] == SKIP) continue;
            vm.prank(v[i]);
            polls.vote(id, choices[i]);
        }
    }

    function _c(uint8 a, uint8 b, uint8 c, uint8 d, uint8 e, uint8 f) internal pure returns (uint8[] memory r) {
        r = new uint8[](6);
        (r[0], r[1], r[2], r[3], r[4], r[5]) = (a, b, c, d, e, f);
    }

    /// 0 final win, 1 final loss, 2 no quorum, 3 tie, 4 not voted, 5 final win (3 opts) => v0: 2 of 3.
    function _scenario() internal {
        _poll(2, _c(0, 0, 0, 1, 1, SKIP), 1 days);
        _poll(2, _c(1, 0, 0, 0, 0, SKIP), 1 days);
        _poll(2, _c(0, 0, SKIP, SKIP, SKIP, SKIP), 1 days);
        _poll(2, _c(0, 0, 0, 1, 1, 1), 1 days);
        _poll(2, _c(SKIP, 0, 0, 0, 1, 1), 1 days);
        _poll(3, _c(2, 2, 2, 0, 1, SKIP), 1 days);
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    function _link(uint256 who, uint256 agentId) internal {
        vm.prank(v[who]);
        cs.link(agentId);
    }

    function _live(uint256 agentId) internal view returns (int128[] memory) {
        return rep.live(agentId, address(cs));
    }

    // ------------------------------------------------------------------ tests

    function test_lifetimeScoreOneLiveEntry() public {
        _link(0, AGENT);
        _scenario();
        cs.attest(aliceVoice);
        int128[] memory l = _live(AGENT);
        assertEq(l.length, 1);
        assertEq(l[0], 66); // 2 of 3
        (uint32 counted, uint32 hits) = cs.scoreOf(aliceVoice);
        assertEq(counted, 3);
        assertEq(hits, 2);
        assertEq(cs.next(aliceVoice), 6);
    }

    /// The v1 attack: attesting one poll at a time used to add one entry per win. Now there is still one entry.
    function test_batchingCannotInflate() public {
        _link(0, AGENT);
        for (uint256 i; i < 5; ++i) {
            _poll(2, _c(0, 0, 0, 1, 1, SKIP), 1 hours); // a win
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            cs.attest(aliceVoice);
        }
        _poll(2, _c(1, 0, 0, 0, 0, SKIP), 1 hours); // a loss
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        cs.attest(aliceVoice);
        int128[] memory l = _live(AGENT);
        assertEq(l.length, 1);
        assertEq(l[0], 83); // 5 of 6
        assertEq(rep.getLastIndex(AGENT, address(cs)), 6); // 6 written, 5 revoked
    }

    function test_stopsAtFirstOpenPollInsteadOfReverting() public {
        _link(0, AGENT);
        _poll(2, _c(0, 0, 0, 1, 1, SKIP), 1 hours); // closes soon
        _poll(2, _c(0, 0, 0, 1, 1, SKIP), 10 days); // stays open
        _poll(2, _c(0, 0, 0, 1, 1, SKIP), 1 hours);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        cs.attest(aliceVoice);
        assertEq(cs.next(aliceVoice), 1);
        vm.expectRevert(CrowdScoreV2.NothingToAttest.selector);
        cs.attest(aliceVoice);
        vm.warp(vm.getBlockTimestamp() + 10 days);
        cs.attest(aliceVoice);
        assertEq(cs.next(aliceVoice), 3);
        (uint32 counted,) = cs.scoreOf(aliceVoice);
        assertEq(counted, 3);
        assertEq(_live(AGENT).length, 1);
    }

    function test_attestWithoutLinkKeepsScoreAndLinkPublishesIt() public {
        _scenario();
        cs.attest(aliceVoice);
        assertEq(rep.getLastIndex(AGENT, address(cs)), 0);
        _link(0, AGENT);
        int128[] memory l = _live(AGENT);
        assertEq(l.length, 1);
        assertEq(l[0], 66);
    }

    function test_relinkMovesTheScore() public {
        _link(0, AGENT);
        _scenario();
        cs.attest(aliceVoice);
        _link(0, AGENT + 1);
        assertEq(_live(AGENT).length, 0);
        assertEq(_live(AGENT + 1).length, 1);
        assertEq(cs.holderOf(AGENT), bytes32(0));
        assertEq(cs.holderOf(AGENT + 1), aliceVoice);
    }

    function test_agentRecordCarriesOnlyOneVoice() public {
        _link(0, AGENT);
        _scenario();
        cs.attest(aliceVoice);
        cs.attest(bobVoice);
        idr.setOwner(AGENT, v[1]); // the record moves to bob's wallet
        _link(1, AGENT);
        (uint256 aAgent, address aOwner) = cs.links(aliceVoice);
        assertEq(aOwner, address(0));
        assertEq(aAgent, 0);
        int128[] memory l = _live(AGENT);
        assertEq(l.length, 1); // only bob's
        (uint256 agentId,) = cs.liveOf(bobVoice);
        assertEq(agentId, AGENT);
        (, uint64 aliceIdx) = cs.liveOf(aliceVoice);
        assertEq(aliceIdx, 0);
    }

    function test_ownerChangedWithdrawsInsteadOfReverting() public {
        _link(0, AGENT);
        _scenario();
        cs.attest(aliceVoice);
        idr.setOwner(AGENT, v[5]);
        _poll(2, _c(0, 0, 0, 1, 1, SKIP), 1 hours);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        cs.attest(aliceVoice); // does not revert
        assertEq(_live(AGENT).length, 0);
        (uint32 counted,) = cs.scoreOf(aliceVoice);
        assertEq(counted, 4);
    }

    function test_brokenRegistryNeverBlocksScoring() public {
        _link(0, AGENT);
        _scenario();
        rep.setBroken(true, false);
        cs.attest(aliceVoice);
        (uint32 counted,) = cs.scoreOf(aliceVoice);
        assertEq(counted, 3);
        rep.setBroken(false, false);
        cs.publish(aliceVoice);
        assertEq(_live(AGENT).length, 1);
    }

    function test_failedRevokeNeverLeavesTwoLiveEntries() public {
        _link(0, AGENT);
        _scenario();
        cs.attest(aliceVoice);
        rep.setBroken(false, true);
        _poll(2, _c(0, 0, 0, 1, 1, SKIP), 1 hours);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        cs.attest(aliceVoice);
        assertEq(_live(AGENT).length, 1);
        assertEq(_live(AGENT)[0], 66); // the old score stays until the revoke works
        rep.setBroken(false, false);
        cs.publish(aliceVoice);
        assertEq(_live(AGENT).length, 1);
        assertEq(_live(AGENT)[0], 75);
    }

    function test_lowGasCannotForceAFailedWrite() public {
        _link(0, AGENT);
        _scenario();
        vm.expectRevert(LiveScore.NeedMoreGas.selector);
        cs.attest{gas: 300_000}(aliceVoice);
        assertEq(cs.next(aliceVoice), 0);
    }

    function test_publishIsRepeatableAndKeepsOne() public {
        _link(0, AGENT);
        _scenario();
        cs.attest(aliceVoice);
        cs.publish(aliceVoice);
        cs.publish(aliceVoice);
        assertEq(_live(AGENT).length, 1);
    }

    function test_maxScanSplitsLongHistories() public {
        creatorIdx = 6;
        uint8[] memory none = new uint8[](0);
        for (uint256 i; i < 30; ++i) {
            vm.prank(v[6 + i]);
            string[] memory o = new string[](2);
            (o[0], o[1]) = ("a", "b");
            polls.createPoll("q?", o, uint64(vm.getBlockTimestamp() + 1 hours));
        }
        none;
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        cs.attest(aliceVoice);
        assertEq(cs.next(aliceVoice), 30);
    }

    function test_linkNeedsAgentIdAndOwnership() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(CrowdScoreV2.NoAgentID.selector);
        cs.link(AGENT);
        vm.prank(v[0]);
        vm.expectRevert(CrowdScoreV2.NotAgentOwner.selector);
        cs.link(AGENT + 2);
        vm.prank(v[0]);
        vm.expectRevert(CrowdScoreV2.NotAgentOwner.selector);
        cs.link(999); // nonexistent
    }
}
