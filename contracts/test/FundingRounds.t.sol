// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundingRounds} from "../src/FundingRounds.sol";
import {OneVoice, IAgentID} from "../src/lib/OneVoice.sol";
import {MockAgentID, Refuser} from "./mocks/MockAgentID.sol";

contract FundingRoundsTest is Test {
    MockAgentID reg;
    FundingRounds fr;
    address steward = makeAddr("steward");
    address sponsor = makeAddr("sponsor"); // no Agent ID; may top up
    address nobody = makeAddr("nobody");
    address[] backers;
    address[] builders;

    uint64 start;
    uint64 end;

    function setUp() public {
        vm.warp(1_790_000_000);
        reg = new MockAgentID();
        fr = new FundingRounds(IAgentID(address(reg)));
        reg.give(steward, "steward");
        vm.deal(steward, 10 ether);
        vm.deal(sponsor, 10 ether);
        for (uint256 i; i < 30; ++i) {
            address b = address(uint160(0xB000 + i));
            reg.give(b, string.concat("backer", vm.toString(i)));
            vm.deal(b, 1 ether);
            backers.push(b);
        }
        for (uint256 i; i < 6; ++i) {
            address p = address(uint160(0xC000 + i));
            reg.give(p, string.concat("builder", vm.toString(i)));
            builders.push(p);
        }
        start = uint64(block.timestamp + 1 hours);
        end = uint64(block.timestamp + 7 days);
    }

    // ------------------------------------------------------------- helpers

    function _round(uint16 capBps) internal returns (uint256 id) {
        vm.prank(steward);
        id = fr.createRound{value: 1 ether}("Round 1", start, end, 0.001 ether, 0.02 ether, capBps);
    }

    function _listAndApprove(uint256 rid, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.prank(builders[i]);
            uint256 pid = fr.applyProject(rid, string.concat("Project ", vm.toString(i)), "https://example.org");
            vm.prank(steward);
            fr.approveProject(rid, pid);
        }
    }

    function _back(uint256 rid, address who, uint256 pid, uint256 amt) internal {
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amts = new uint256[](1);
        ids[0] = pid;
        amts[0] = amt;
        vm.prank(who);
        fr.back{value: amt}(rid, ids, amts);
    }

    function _settle(uint256 rid) internal {
        vm.warp(end + 24 hours);
        fr.finalise(rid);
    }

    // --------------------------------------------------------------- tests

    /// The report's worked example: same money raised, 20 people vs 1 person.
    function test_crowdBeatsWhale() public {
        uint256 rid = _round(10_000);
        _listAndApprove(rid, 2);
        vm.warp(start);
        for (uint256 i; i < 20; ++i) _back(rid, backers[i], 0, 0.001 ether);
        _back(rid, backers[20], 1, 0.02 ether);
        assertEq(fr.getProject(rid, 0).raised, fr.getProject(rid, 1).raised);
        assertGt(fr.weightOf(rid, 0), 0);
        assertEq(fr.weightOf(rid, 1), 0); // one backer: no matching, whatever they pay

        _settle(rid);
        assertEq(fr.getProject(rid, 0).matched, 1 ether);
        assertEq(fr.getProject(rid, 1).matched, 0);

        uint256 b0 = builders[0].balance;
        vm.prank(builders[0]);
        fr.claim(rid, 0);
        assertEq(builders[0].balance - b0, 1.02 ether);
        vm.prank(builders[1]);
        fr.claim(rid, 1);
        assertEq(builders[1].balance, 0.02 ether);
        assertEq(address(fr).balance, 0);
    }

    function test_fiveBackerMinimum() public {
        uint256 rid = _round(10_000);
        _listAndApprove(rid, 1);
        vm.warp(start);
        for (uint256 i; i < 4; ++i) _back(rid, backers[i], 0, 0.02 ether);
        assertEq(fr.weightOf(rid, 0), 0);
        _back(rid, backers[4], 0, 0.001 ether);
        assertGt(fr.weightOf(rid, 0), 0);
        assertTrue(fr.backedByAtLeast(rid, 0, 5));
    }

    function test_capAndWaterFilling() public {
        uint256 rid = _round(4_000); // 40% cap
        _listAndApprove(rid, 3);
        vm.warp(start);
        for (uint256 i; i < 20; ++i) _back(rid, backers[i], 0, 0.01 ether); // dominant
        for (uint256 i; i < 6; ++i) _back(rid, backers[20 + i], 1, 0.01 ether);
        for (uint256 i; i < 5; ++i) _back(rid, backers[i], 2, 0.005 ether);
        _settle(rid);
        uint256 m0 = fr.getProject(rid, 0).matched;
        uint256 m1 = fr.getProject(rid, 1).matched;
        uint256 m2 = fr.getProject(rid, 2).matched;
        assertEq(m0, 0.4 ether); // pinned at cap
        assertLe(m1, 0.4 ether);
        assertLe(m2, 0.4 ether);
        assertGt(m1, m2);
        assertApproxEqAbs(m0 + m1 + m2, 1 ether, 10); // freed share is passed on, not lost
        assertEq(fr.getRound(rid).matchedTotal, m0 + m1 + m2);
    }

    function test_allCappedReturnsLeftoverToFunders() public {
        uint256 rid = _round(2_000); // 20% cap, but only two eligible projects
        vm.prank(sponsor);
        fr.topUpPool{value: 1 ether}(rid);
        _listAndApprove(rid, 2);
        vm.warp(start);
        for (uint256 i; i < 6; ++i) {
            _back(rid, backers[i], 0, 0.01 ether);
            _back(rid, backers[i + 6], 1, 0.01 ether);
        }
        _settle(rid);
        assertEq(fr.getProject(rid, 0).matched, 0.4 ether);
        assertEq(fr.getProject(rid, 1).matched, 0.4 ether);
        // 1.2 ether unused, split 1:1 between steward and sponsor
        uint256 s0 = steward.balance;
        vm.prank(steward);
        fr.withdrawPool(rid);
        assertEq(steward.balance - s0, 0.6 ether);
        uint256 p0 = sponsor.balance;
        vm.prank(sponsor);
        fr.withdrawPool(rid);
        assertEq(sponsor.balance - p0, 0.6 ether);
        vm.prank(sponsor);
        vm.expectRevert(FundingRounds.NothingToWithdraw.selector);
        fr.withdrawPool(rid);
    }

    function test_delistRefundsBackers() public {
        uint256 rid = _round(10_000);
        _listAndApprove(rid, 2);
        vm.warp(start);
        for (uint256 i; i < 6; ++i) {
            _back(rid, backers[i], 0, 0.01 ether);
            _back(rid, backers[i + 6], 1, 0.01 ether);
        }
        vm.warp(end + 1 hours); // inside the review window
        vm.prank(steward);
        fr.delistProject(rid, 1, "ring of linked accounts");
        uint256 b = backers[6].balance;
        vm.prank(backers[6]);
        fr.refund(rid, 1);
        assertEq(backers[6].balance - b, 0.01 ether);
        vm.prank(backers[6]);
        vm.expectRevert(FundingRounds.NothingToRefund.selector);
        fr.refund(rid, 1);
        // live project's backers cannot refund
        vm.prank(backers[0]);
        vm.expectRevert(FundingRounds.NothingToRefund.selector);
        fr.refund(rid, 0);

        _settle(rid);
        assertEq(fr.getProject(rid, 0).matched, 1 ether);
        vm.prank(builders[1]);
        vm.expectRevert(FundingRounds.WrongStatus.selector);
        fr.claim(rid, 1);
    }

    function test_cancelRefundsEveryone() public {
        uint256 rid = _round(10_000);
        vm.prank(sponsor);
        fr.topUpPool{value: 0.5 ether}(rid);
        _listAndApprove(rid, 1);
        vm.warp(start);
        for (uint256 i; i < 5; ++i) _back(rid, backers[i], 0, 0.02 ether);
        vm.prank(steward);
        fr.cancelRound(rid, "test");
        for (uint256 i; i < 5; ++i) {
            vm.prank(backers[i]);
            fr.refund(rid, 0);
        }
        vm.prank(steward);
        fr.withdrawPool(rid);
        vm.prank(sponsor);
        fr.withdrawPool(rid);
        assertEq(address(fr).balance, 0);
        vm.expectRevert(FundingRounds.RoundIsFinal.selector);
        fr.finalise(rid);
    }

    function test_exitsWorkWhenRegistryBreaks() public {
        uint256 rid = _round(10_000);
        _listAndApprove(rid, 1);
        vm.warp(start);
        for (uint256 i; i < 5; ++i) _back(rid, backers[i], 0, 0.01 ether);
        reg.setBroken(true);
        vm.prank(backers[5]);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amts = new uint256[](1);
        amts[0] = 0.01 ether;
        vm.expectRevert(OneVoice.RegistryUnavailable.selector);
        fr.back{value: 0.01 ether}(rid, ids, amts);
        _settle(rid);
        vm.prank(builders[0]);
        fr.claim(rid, 0); // the only project took the whole pool, paid out with the registry down
        assertEq(address(fr).balance, 0);
    }

    function test_backingRules() public {
        uint256 rid = _round(10_000);
        _listAndApprove(rid, 2);
        vm.prank(builders[2]);
        fr.applyProject(rid, "Pending", "");

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amts = new uint256[](1);
        amts[0] = 0.01 ether;
        vm.prank(backers[0]);
        vm.expectRevert(FundingRounds.RoundNotOpen.selector);
        fr.back{value: 0.01 ether}(rid, ids, amts);

        vm.warp(start);
        vm.startPrank(backers[0]);
        amts[0] = 0.0005 ether;
        vm.expectRevert(FundingRounds.BadAmounts.selector); // below minimum
        fr.back{value: 0.0005 ether}(rid, ids, amts);
        amts[0] = 0.021 ether;
        vm.expectRevert(FundingRounds.BadAmounts.selector); // above maximum
        fr.back{value: 0.021 ether}(rid, ids, amts);
        amts[0] = 0.01 ether;
        vm.expectRevert(FundingRounds.BadAmounts.selector); // value mismatch
        fr.back{value: 0.02 ether}(rid, ids, amts);
        fr.back{value: 0.01 ether}(rid, ids, amts);
        amts[0] = 0.011 ether;
        vm.expectRevert(FundingRounds.BadAmounts.selector); // cumulative cap per Agent ID
        fr.back{value: 0.011 ether}(rid, ids, amts);
        ids[0] = 2;
        amts[0] = 0.01 ether;
        vm.expectRevert(FundingRounds.WrongStatus.selector); // pending project
        fr.back{value: 0.01 ether}(rid, ids, amts);
        vm.stopPrank();

        ids[0] = 0;
        vm.prank(builders[0]);
        vm.deal(builders[0], 1 ether);
        vm.expectRevert(FundingRounds.OwnProject.selector);
        fr.back{value: 0.01 ether}(rid, ids, amts);

        vm.deal(nobody, 1 ether);
        vm.prank(nobody);
        vm.expectRevert(OneVoice.NoAgentID.selector);
        fr.back{value: 0.01 ether}(rid, ids, amts);
    }

    function test_splitBackingAcrossProjects() public {
        uint256 rid = _round(10_000);
        _listAndApprove(rid, 3);
        vm.warp(start);
        uint256[] memory ids = new uint256[](3);
        uint256[] memory amts = new uint256[](3);
        ids[0] = 0;
        ids[1] = 1;
        ids[2] = 2;
        amts[0] = 0.001 ether;
        amts[1] = 0.002 ether;
        amts[2] = 0.003 ether;
        vm.prank(backers[0]);
        fr.back{value: 0.006 ether}(rid, ids, amts);
        assertEq(fr.getProject(rid, 2).raised, 0.003 ether);
        assertEq(fr.projectsBackedBy(rid, keccak256("backer0")), 3);
        // topping up the same project counts the same voice once
        _back(rid, backers[0], 0, 0.004 ether);
        assertEq(fr.getProject(rid, 0).backers, 1);
        assertEq(fr.paidByVoice(rid, 0, keccak256("backer0")), 0.005 ether);
    }

    function test_stewardPowersAreLimited() public {
        uint256 rid = _round(10_000);
        _listAndApprove(rid, 1);
        vm.prank(backers[0]);
        vm.expectRevert(FundingRounds.NotSteward.selector);
        fr.cancelRound(rid, "x");
        vm.prank(backers[0]);
        vm.expectRevert(FundingRounds.NotSteward.selector);
        fr.delistProject(rid, 0, "x");
        vm.warp(start);
        for (uint256 i; i < 5; ++i) _back(rid, backers[i], 0, 0.01 ether);
        vm.warp(end);
        vm.prank(steward);
        vm.expectRevert(FundingRounds.RoundEnded.selector);
        fr.approveProject(rid, 0);
        vm.expectRevert(FundingRounds.ReviewNotOver.selector);
        fr.finalise(rid);
        _settle(rid);
        vm.startPrank(steward);
        vm.expectRevert(FundingRounds.RoundIsFinal.selector);
        fr.cancelRound(rid, "too late");
        vm.expectRevert(FundingRounds.RoundIsFinal.selector);
        fr.delistProject(rid, 0, "too late");
        vm.stopPrank();
        // steward cannot claim a project's money
        vm.prank(steward);
        vm.expectRevert(FundingRounds.NotProjectWallet.selector);
        fr.claim(rid, 0);
    }

    function test_createRoundValidation() public {
        vm.startPrank(steward);
        vm.expectRevert(FundingRounds.SeedTooSmall.selector);
        fr.createRound{value: 0.005 ether}("r", start, end, 1, 2, 2000);
        vm.expectRevert(FundingRounds.BadTimes.selector);
        fr.createRound{value: 0.1 ether}("r", end, start, 1, 2, 2000);
        vm.expectRevert(FundingRounds.BadTimes.selector);
        fr.createRound{value: 0.1 ether}("r", start, start + 61 days, 1, 2, 2000);
        // a start time in the past means "start now"
        uint256 rid = fr.createRound{value: 0.1 ether}("r", uint64(block.timestamp - 10), end, 1, 2, 2000);
        assertEq(fr.getRound(rid).startsAt, block.timestamp);
        vm.expectRevert(FundingRounds.BadLimits.selector);
        fr.createRound{value: 0.1 ether}("r", start, end, 3, 2, 2000);
        vm.expectRevert(FundingRounds.BadCap.selector);
        fr.createRound{value: 0.1 ether}("r", start, end, 1, 2, 100);
        vm.expectRevert(FundingRounds.BadText.selector);
        fr.createRound{value: 0.1 ether}("", start, end, 1, 2, 2000);
        vm.stopPrank();
        vm.deal(nobody, 1 ether);
        vm.prank(nobody);
        vm.expectRevert(OneVoice.NoAgentID.selector);
        fr.createRound{value: 0.1 ether}("r", start, end, 1, 2, 2000);
    }

    function test_oneProjectPerAgentIDAndMaxApproved() public {
        uint256 rid = _round(10_000);
        vm.startPrank(builders[0]);
        fr.applyProject(rid, "A", "");
        vm.expectRevert(FundingRounds.AlreadyApplied.selector);
        fr.applyProject(rid, "B", "");
        vm.stopPrank();
        for (uint256 i; i < 40; ++i) {
            address a = address(uint160(0xD000 + i));
            reg.give(a, string.concat("p", vm.toString(i)));
            vm.prank(a);
            uint256 pid = fr.applyProject(rid, "P", "");
            vm.prank(steward);
            fr.approveProject(rid, pid);
        }
        vm.prank(steward);
        vm.expectRevert(FundingRounds.TooManyProjects.selector);
        fr.approveProject(rid, 0);
    }

    function test_refusingWalletOnlyHurtsItself() public {
        uint256 rid = _round(10_000);
        Refuser r = new Refuser();
        reg.give(address(r), "refuser");
        vm.prank(address(r));
        fr.applyProject(rid, "R", "");
        vm.prank(steward);
        fr.approveProject(rid, 0);
        _listAndApprove(rid, 1); // project 1
        vm.warp(start);
        for (uint256 i; i < 5; ++i) {
            _back(rid, backers[i], 0, 0.01 ether);
            _back(rid, backers[i + 5], 1, 0.01 ether);
        }
        _settle(rid);
        vm.prank(address(r));
        vm.expectRevert(FundingRounds.TransferFailed.selector);
        fr.claim(rid, 0);
        vm.prank(builders[0]);
        fr.claim(rid, 1);
    }

    /// 40 projects with many backers still finalise in one transaction, well under a block's gas.
    function test_finaliseGasAtMaxSize() public {
        uint256 rid = _round(2_000);
        for (uint256 i; i < 40; ++i) {
            address a = address(uint160(0xD000 + i));
            reg.give(a, string.concat("p", vm.toString(i)));
            vm.prank(a);
            fr.applyProject(rid, "P", "");
            vm.prank(steward);
            fr.approveProject(rid, i);
        }
        vm.warp(start);
        for (uint256 i; i < 40; ++i) {
            for (uint256 j; j < 5 + (i % 7); ++j) _back(rid, backers[(i + j) % 30], i, 0.001 ether * (1 + j));
        }
        vm.warp(end + 24 hours);
        uint256 g = gasleft();
        fr.finalise(rid);
        uint256 used = g - gasleft();
        emit log_named_uint("finalise gas (40 projects)", used);
        assertLt(used, 5_000_000);
        uint256 sum;
        for (uint256 i; i < 40; ++i) sum += fr.getProject(rid, i).matched;
        assertLe(sum, 1 ether);
        assertEq(sum, fr.getRound(rid).matchedTotal);
    }

    function testFuzz_sumOfSharesNeverExceedsPool(uint256 seed, uint16 capBps) public {
        capBps = uint16(bound(capBps, 500, 10_000));
        uint256 rid = _round(capBps);
        _listAndApprove(rid, 6);
        vm.warp(start);
        for (uint256 i; i < 30; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 pid = r % 6;
            uint256 amt = 0.001 ether + (r >> 8) % 0.019 ether;
            _back(rid, backers[i], pid, amt);
        }
        _settle(rid);
        uint256 sum;
        uint256 cap = (1 ether * uint256(capBps)) / 10_000;
        for (uint256 i; i < 6; ++i) {
            uint256 m = fr.getProject(rid, i).matched;
            assertLe(m, cap);
            sum += m;
        }
        assertLe(sum, 1 ether);
        // everything owed can be paid out, leaving at most rounding dust
        for (uint256 i; i < 6; ++i) {
            if (fr.getProject(rid, i).raised + fr.getProject(rid, i).matched > 0) {
                vm.prank(builders[i]);
                fr.claim(rid, i);
            }
        }
        vm.prank(steward);
        try fr.withdrawPool(rid) {} catch {}
        assertLt(address(fr).balance, 100);
    }
}
