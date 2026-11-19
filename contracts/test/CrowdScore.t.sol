// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Polls} from "../src/Polls.sol";
import {CrowdScore} from "../src/CrowdScore.sol";
import {IERC8004Identity, IERC8004Reputation} from "../src/Attestor.sol";
import {IAgentID} from "../src/lib/OneVoice.sol";
import {MockAgentID} from "./mocks/MockAgentID.sol";

/// @dev Minimal ERC-8004 identity: an owner per agent id, reverting for unknown ids like ERC-721 does.
contract MockIdentity {
    mapping(uint256 => address) public owners;

    function setOwner(uint256 agentId, address who) external {
        owners[agentId] = who;
    }

    function ownerOf(uint256 agentId) external view returns (address o) {
        o = owners[agentId];
        require(o != address(0), "nonexistent");
    }
}

/// @dev Records every giveFeedback call.
contract MockReputation {
    struct Call {
        address sender;
        uint256 agentId;
        int128 value;
        uint8 valueDecimals;
        string tag1;
        string tag2;
        string endpoint;
        string feedbackURI;
        bytes32 feedbackHash;
    }

    Call[] public calls;

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external {
        calls.push(
            Call(msg.sender, agentId, value, valueDecimals, tag1, tag2, endpoint, feedbackURI, feedbackHash)
        );
    }

    function count() external view returns (uint256) {
        return calls.length;
    }

    function get(uint256 i) external view returns (Call memory) {
        return calls[i];
    }
}

contract CrowdScoreTest is Test {
    uint8 constant SKIP = type(uint8).max;

    MockAgentID reg;
    MockIdentity idr;
    MockReputation rep;
    Polls polls;
    CrowdScore cs;

    address[] v; // v[0] is the voter under test
    address nobody = makeAddr("nobody");
    bytes32 aliceVoice = keccak256("voter0");
    uint256 constant AGENT = 42;

    event Linked(bytes32 indexed voice, uint256 indexed agentId, address indexed owner);
    event Attested(
        bytes32 indexed voice,
        uint256 indexed agentId,
        uint256 from,
        uint256 to,
        uint32 counted,
        uint32 matched,
        bytes32 hash
    );

    function setUp() public {
        reg = new MockAgentID();
        polls = new Polls(IAgentID(address(reg)));
        idr = new MockIdentity();
        rep = new MockReputation();
        cs = new CrowdScore(polls, IERC8004Identity(address(idr)), IERC8004Reputation(address(rep)));
        for (uint256 i; i < 14; ++i) {
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

    uint256 creatorIdx = 6; // creators v[6..13] never vote, so each poll gets a fresh creator

    /// choices[i] is the option voter v[i] picks, or SKIP.
    function _poll(uint256 nOpts, uint8[] memory choices, uint64 duration) internal returns (uint256 id) {
        string[] memory o = new string[](nOpts);
        for (uint256 i; i < nOpts; ++i) {
            o[i] = string.concat("opt", vm.toString(i));
        }
        vm.prank(v[creatorIdx++]);
        id = polls.createPoll("q?", o, uint64(block.timestamp + duration));
        for (uint256 i; i < choices.length; ++i) {
            if (choices[i] == SKIP) continue;
            vm.prank(v[i]);
            polls.vote(id, choices[i]);
        }
    }

    function _c(uint8 a, uint8 b, uint8 c, uint8 d, uint8 e, uint8 f)
        internal
        pure
        returns (uint8[] memory r)
    {
        r = new uint8[](6);
        (r[0], r[1], r[2], r[3], r[4], r[5]) = (a, b, c, d, e, f);
    }

    /// The scenario from the spec: 0 final win, 1 final loss, 2 no quorum, 3 tie, 4 not voted, 5 final win (3 opts).
    function _scenario() internal {
        _poll(2, _c(0, 0, 0, 1, 1, SKIP), 1 days); // 3-2, winner 0, v0 matched
        _poll(2, _c(1, 0, 0, 0, 0, SKIP), 1 days); // 4-1, winner 0, v0 missed
        _poll(2, _c(0, 0, SKIP, SKIP, SKIP, SKIP), 1 days); // 2 votes: no quorum
        _poll(2, _c(0, 0, 0, 1, 1, 1), 1 days); // 3-3: tie
        _poll(2, _c(SKIP, 0, 0, 0, 1, 1), 1 days); // final, v0 did not vote
        _poll(3, _c(2, 2, 2, 0, 1, SKIP), 1 days); // 1-1-3, winner 2, v0 matched
        vm.warp(block.timestamp + 1 days);
    }

    function _hash(bytes32 voice, uint256 from, uint256 to, uint32 counted, uint32 matched)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(polls), voice, from, to, counted, matched));
    }

    // -------------------------------------------------------------------- link

    function test_link() public {
        vm.expectEmit(address(cs));
        emit Linked(aliceVoice, AGENT, v[0]);
        vm.prank(v[0]);
        uint256 g = gasleft();
        cs.link(AGENT);
        emit log_named_uint("link gas (mocks)", g - gasleft());
        (uint256 id, address owner) = cs.links(aliceVoice);
        assertEq(id, AGENT);
        assertEq(owner, v[0]);

        // re-linking to another record the voice owns replaces it
        vm.expectEmit(address(cs));
        emit Linked(aliceVoice, AGENT + 1, v[0]);
        vm.prank(v[0]);
        cs.link(AGENT + 1);
        (id,) = cs.links(aliceVoice);
        assertEq(id, AGENT + 1);
    }

    function test_link_noAgentID() public {
        idr.setOwner(7, nobody);
        vm.prank(nobody);
        vm.expectRevert(CrowdScore.NoAgentID.selector);
        cs.link(7);
    }

    function test_link_notAgentOwner() public {
        vm.prank(v[0]);
        vm.expectRevert(CrowdScore.NotAgentOwner.selector);
        cs.link(AGENT + 2); // owned by v[1]
    }

    // ------------------------------------------------------------------ attest

    function test_attest_counting() public {
        _scenario();
        (uint256 from, uint256 to, uint32 counted, uint32 matched) = cs.preview(aliceVoice, 6);
        assertEq(from, 0);
        assertEq(to, 6);
        assertEq(counted, 3); // polls 0, 1, 5
        assertEq(matched, 2); // polls 0, 5

        vm.prank(v[0]);
        cs.link(AGENT);
        bytes32 h = _hash(aliceVoice, 0, 6, 3, 2);
        vm.expectEmit(address(cs));
        emit Attested(aliceVoice, AGENT, 0, 6, 3, 2, h);
        vm.prank(nobody); // anyone may attest
        uint256 g = gasleft();
        cs.attest(aliceVoice, 6);
        emit log_named_uint("attest gas, 6 polls / 4 voted (mocks)", g - gasleft());

        assertEq(cs.next(aliceVoice), 6);
        assertEq(rep.count(), 1);
        MockReputation.Call memory c = rep.get(0);
        assertEq(c.sender, address(cs));
        assertEq(c.agentId, AGENT);
        assertEq(c.value, 66); // 2 * 100 / 3
        assertEq(c.valueDecimals, 0);
        assertEq(c.tag1, "crowd-accuracy");
        assertEq(c.tag2, "showofhands");
        assertEq(c.endpoint, "https://showofhands.io/#/league");
        assertEq(c.feedbackURI, "");
        assertEq(c.feedbackHash, h);
    }

    function test_otherVoterCountedSeparately() public {
        _scenario();
        // v[1] voted 0 in polls 0,1,2,3,4 and 2 in poll 5: final ones are 0,1,4,5 — all winners
        (,, uint32 counted, uint32 matched) = cs.preview(keccak256("voter1"), 6);
        assertEq(counted, 4);
        assertEq(matched, 4);
        // v[3] voted 1,0,-,1,0,0: final ones 0 (lost), 1 (won), 4 (won), 5 (lost)
        (,, counted, matched) = cs.preview(keccak256("voter3"), 6);
        assertEq(counted, 4);
        assertEq(matched, 2);
    }

    function test_cherryPickPrevented() public {
        _poll(2, _c(1, 0, 0, 0, 0, SKIP), 1 days); // 0: v0 loses
        _poll(2, _c(0, 0, 0, 0, 1, SKIP), 1 days); // 1: v0 wins
        vm.warp(block.timestamp + 1 days);
        vm.prank(v[0]);
        cs.link(AGENT);

        // there is no way to start at poll 1: the range always starts at next[voice] = 0
        (uint256 from,, uint32 counted, uint32 matched) = cs.preview(aliceVoice, 2);
        assertEq(from, 0);
        assertEq(counted, 2);
        assertEq(matched, 1);

        // attesting just poll 0 records the loss; poll 0 can then never be counted again or skipped
        cs.attest(aliceVoice, 1);
        assertEq(rep.get(0).value, 0);
        assertEq(cs.next(aliceVoice), 1);
        vm.expectRevert(CrowdScore.EmptyRange.selector);
        cs.attest(aliceVoice, 1);
        (from,,,) = cs.preview(aliceVoice, 2);
        assertEq(from, 1);
    }

    function test_pollStillOpen() public {
        _poll(2, _c(0, 0, 0, 0, 0, SKIP), 1 days); // 0: closes first
        _poll(2, _c(0, 0, 0, 0, 0, SKIP), 3 days); // 1: still open after the warp
        _poll(2, _c(0, 0, 0, 0, 0, SKIP), 1 days); // 2
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(CrowdScore.PollStillOpen.selector, 1));
        cs.attest(aliceVoice, 3);
        vm.expectRevert(abi.encodeWithSelector(CrowdScore.PollStillOpen.selector, 1));
        cs.preview(aliceVoice, 2);
        // a poll the voice did not vote in still blocks the range while open
        vm.expectRevert(abi.encodeWithSelector(CrowdScore.PollStillOpen.selector, 1));
        cs.attest(keccak256("voter11"), 2);
    }

    function test_rangeChecks() public {
        vm.expectRevert(CrowdScore.RangeTooLong.selector);
        cs.attest(aliceVoice, 101);
        vm.expectRevert(CrowdScore.EmptyRange.selector);
        cs.attest(aliceVoice, 0);
        vm.expectRevert(CrowdScore.NoSuchPoll.selector);
        cs.attest(aliceVoice, 1); // no polls yet
    }

    function test_maxScanFits() public {
        // 100 closed polls, the voter under test voted in all of them: worst case for one call
        address[] memory voters = new address[](5);
        for (uint256 i; i < 5; ++i) {
            voters[i] = v[i];
        }
        string[] memory o = new string[](8);
        for (uint256 i; i < 8; ++i) {
            o[i] = string.concat("a fairly long option text number ", vm.toString(i));
        }
        for (uint256 p; p < 100; ++p) {
            vm.prank(v[6 + (p % 6)]);
            uint256 id = polls.createPoll(
                "A question of moderate length, as users would write?",
                o,
                uint64(vm.getBlockTimestamp() + 1 hours)
            );
            for (uint256 i; i < 5; ++i) {
                vm.prank(voters[i]);
                polls.vote(id, uint8(i == 4 ? 1 : 0));
            }
            vm.warp(vm.getBlockTimestamp() + 1 hours);
        }
        vm.prank(v[0]);
        cs.link(AGENT);
        uint256 g = gasleft();
        cs.attest(aliceVoice, 100);
        emit log_named_uint("attest gas, 100 voted polls, 8 options (mocks)", g - gasleft());
        assertEq(rep.get(0).value, 100);
        vm.expectRevert(CrowdScore.EmptyRange.selector);
        cs.attest(aliceVoice, 100);
    }

    function test_nothingCounted_advancesWithoutFeedbackOrLink() public {
        _scenario();
        bytes32 v11 = keccak256("voter11"); // never voted, never linked
        vm.expectEmit(address(cs));
        emit Attested(v11, 0, 0, 6, 0, 0, _hash(v11, 0, 6, 0, 0));
        cs.attest(v11, 6);
        assertEq(cs.next(v11), 6);
        assertEq(rep.count(), 0);
    }

    function test_notLinked() public {
        _scenario();
        vm.expectRevert(CrowdScore.NotLinked.selector); // v0 voted in final polls but linked no record
        cs.attest(aliceVoice, 2);
        assertEq(cs.next(aliceVoice), 0);
    }

    function test_noQuorumTieAndUnvotedAloneCountNothing() public {
        _poll(2, _c(0, 0, SKIP, SKIP, SKIP, SKIP), 1 days); // no quorum
        _poll(2, _c(0, 0, 0, 1, 1, 1), 1 days); // tie
        _poll(2, _c(SKIP, 0, 0, 0, 1, 1), 1 days); // final, not voted
        vm.warp(block.timestamp + 1 days);
        cs.attest(aliceVoice, 3); // unlinked, still fine
        assertEq(cs.next(aliceVoice), 3);
        assertEq(rep.count(), 0);
    }

    function test_ownerChanged() public {
        _scenario();
        vm.prank(v[0]);
        cs.link(AGENT);
        idr.setOwner(AGENT, nobody); // the ERC-8004 record changed hands
        vm.expectRevert(CrowdScore.OwnerChanged.selector);
        cs.attest(aliceVoice, 6);
        assertEq(cs.next(aliceVoice), 0); // reverted as a whole
    }

    function test_repeatedAttestContinuesFromPointer() public {
        _scenario();
        vm.prank(v[0]);
        cs.link(AGENT);
        cs.attest(aliceVoice, 2); // polls 0,1: 1 of 2
        assertEq(cs.next(aliceVoice), 2);
        (uint256 from, uint256 to, uint32 counted, uint32 matched) = cs.preview(aliceVoice, 6);
        assertEq(from, 2);
        assertEq(to, 6);
        assertEq(counted, 1); // poll 5
        assertEq(matched, 1);
        vm.expectEmit(address(cs));
        emit Attested(aliceVoice, AGENT, 2, 6, 1, 1, _hash(aliceVoice, 2, 6, 1, 1));
        cs.attest(aliceVoice, 6);
        assertEq(rep.count(), 2);
        assertEq(rep.get(0).value, 50);
        assertEq(rep.get(1).value, 100);
        assertEq(rep.get(0).feedbackHash, _hash(aliceVoice, 0, 2, 2, 1));
        assertEq(rep.get(1).feedbackHash, _hash(aliceVoice, 2, 6, 1, 1));

        // later polls continue from 6
        _poll(2, _c(1, 0, 0, 0, 0, SKIP), 1 days);
        vm.warp(block.timestamp + 1 days);
        (from,,,) = cs.preview(aliceVoice, 7);
        assertEq(from, 6);
    }

    function test_relinkSendsLaterScoresToNewRecord() public {
        _scenario();
        vm.prank(v[0]);
        cs.link(AGENT);
        cs.attest(aliceVoice, 2);
        vm.prank(v[0]);
        cs.link(AGENT + 1);
        cs.attest(aliceVoice, 6);
        assertEq(rep.get(0).agentId, AGENT);
        assertEq(rep.get(1).agentId, AGENT + 1);
    }
}
