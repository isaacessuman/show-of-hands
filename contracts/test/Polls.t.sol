// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Polls} from "../src/Polls.sol";
import {OneVoice, IAgentID} from "../src/lib/OneVoice.sol";
import {MockAgentID} from "./mocks/MockAgentID.sol";

contract PollsTest is Test {
    MockAgentID reg;
    Polls polls;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address nobody = makeAddr("nobody");

    function setUp() public {
        reg = new MockAgentID();
        polls = new Polls(IAgentID(address(reg)));
        reg.give(alice, "alice");
        reg.give(bob, "bob");
        reg.give(carol, "carol");
    }

    function _opts(uint256 n) internal pure returns (string[] memory o) {
        o = new string[](n);
        for (uint256 i; i < n; ++i) o[i] = string.concat("option ", vm.toString(i));
    }

    function _create(address who) internal returns (uint256) {
        vm.prank(who);
        return polls.createPoll("Which feature next?", _opts(3), uint64(block.timestamp + 1 days));
    }

    function test_createAndVote() public {
        uint256 id = _create(alice);
        vm.prank(bob);
        polls.vote(id, 2);
        vm.prank(carol);
        polls.vote(id, 2);
        vm.prank(alice);
        polls.vote(id, 0);
        (bytes32 cv, address creator,,, uint32 total, string memory q, string[] memory o, uint32[] memory t) =
            polls.getPoll(id);
        assertEq(cv, keccak256("alice"));
        assertEq(creator, alice);
        assertEq(total, 3);
        assertEq(q, "Which feature next?");
        assertEq(o.length, 3);
        assertEq(t[0], 1);
        assertEq(t[2], 2);
        (bool voted, uint8 opt) = polls.hasVoted(id, bob);
        assertTrue(voted);
        assertEq(opt, 2);
        (voted,) = polls.hasVoted(id, nobody);
        assertFalse(voted);
        assertEq(polls.votesCastBy(keccak256("bob")), 1);
    }

    function test_oneVotePerAgentID() public {
        uint256 id = _create(alice);
        vm.startPrank(bob);
        polls.vote(id, 1);
        vm.expectRevert(Polls.AlreadyVoted.selector);
        polls.vote(id, 0);
        vm.stopPrank();
    }

    function test_nonHolderCannotVoteOrCreate() public {
        uint256 id = _create(alice);
        vm.startPrank(nobody);
        vm.expectRevert(OneVoice.NoAgentID.selector);
        polls.vote(id, 0);
        vm.expectRevert(OneVoice.NoAgentID.selector);
        polls.createPoll("q", _opts(2), uint64(block.timestamp + 1 days));
        vm.stopPrank();
    }

    function test_roundTripBlocksBorrowedName() public {
        uint256 id = _create(alice);
        reg.setForgedOwner(carol); // name no longer points back to the caller
        vm.prank(bob);
        vm.expectRevert(OneVoice.NoAgentID.selector);
        polls.vote(id, 0);
    }

    function test_brokenRegistryFailsCleanly() public {
        uint256 id = _create(alice);
        reg.setBroken(true);
        vm.prank(bob);
        vm.expectRevert(OneVoice.RegistryUnavailable.selector);
        polls.vote(id, 0);
        assertEq(polls.voiceOf(bob), bytes32(0));
    }

    function test_oneOpenPollPerAgentID() public {
        uint256 id = _create(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Polls.OpenPollExists.selector, id));
        polls.createPoll("again", _opts(2), uint64(block.timestamp + 2 days));
        vm.warp(block.timestamp + 1 days);
        uint256 id2 = _create(alice);
        assertEq(id2, id + 1);
    }

    function test_closedPollRejectsVotes() public {
        uint256 id = _create(alice);
        vm.warp(block.timestamp + 1 days);
        assertFalse(polls.isOpen(id));
        vm.prank(bob);
        vm.expectRevert(Polls.PollClosed.selector);
        polls.vote(id, 0);
    }

    function test_inputLimits() public {
        vm.startPrank(alice);
        uint64 end = uint64(block.timestamp + 1 days);
        vm.expectRevert(Polls.BadOptionCount.selector);
        polls.createPoll("q", _opts(1), end);
        vm.expectRevert(Polls.BadOptionCount.selector);
        polls.createPoll("q", _opts(9), end);
        vm.expectRevert(Polls.EmptyText.selector);
        polls.createPoll("", _opts(2), end);
        vm.expectRevert(Polls.TextTooLong.selector);
        polls.createPoll(string(new bytes(281)), _opts(2), end);
        vm.expectRevert(Polls.BadEndTime.selector);
        polls.createPoll("q", _opts(2), uint64(block.timestamp + 30 minutes));
        vm.expectRevert(Polls.BadEndTime.selector);
        polls.createPoll("q", _opts(2), uint64(block.timestamp + 31 days));
        uint256 id = polls.createPoll("q", _opts(2), end);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(Polls.BadOption.selector);
        polls.vote(id, 2);
        vm.expectRevert(Polls.NoSuchPoll.selector);
        polls.vote(99, 0);
    }

    function testFuzz_talliesMatchVoters(uint8 nVoters, uint256 seed) public {
        nVoters = uint8(bound(nVoters, 1, 60));
        uint256 id = _create(alice);
        uint256[3] memory expect;
        for (uint256 i; i < nVoters; ++i) {
            address v = address(uint160(0x1000 + i));
            reg.give(v, string.concat("v", vm.toString(i)));
            uint8 opt = uint8(uint256(keccak256(abi.encode(seed, i))) % 3);
            vm.prank(v);
            polls.vote(id, opt);
            expect[opt]++;
        }
        (,,,, uint32 total,,, uint32[] memory t) = polls.getPoll(id);
        assertEq(total, nVoters);
        for (uint256 i; i < 3; ++i) assertEq(t[i], expect[i]);
    }
}
