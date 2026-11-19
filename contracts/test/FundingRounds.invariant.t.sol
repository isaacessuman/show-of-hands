// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundingRounds} from "../src/FundingRounds.sol";
import {IAgentID} from "../src/lib/OneVoice.sol";
import {MockAgentID} from "./mocks/MockAgentID.sol";

/// Random sequences of every public action; tracks what the contract owes.
contract Handler is Test {
    FundingRounds public fr;
    MockAgentID public reg;
    address public steward;
    address[] public actors;
    uint256 public rid;
    uint64 public endsAt;

    constructor(FundingRounds _fr, MockAgentID _reg, address _steward, uint256 _rid, uint64 _endsAt) {
        fr = _fr;
        reg = _reg;
        steward = _steward;
        rid = _rid;
        endsAt = _endsAt;
        for (uint256 i; i < 12; ++i) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            vm.deal(a, 100 ether);
        }
    }

    function _a(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function back(uint256 s, uint256 pid, uint256 amt) external {
        pid = bound(pid, 0, 4);
        amt = bound(amt, 0.001 ether, 0.02 ether);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amts = new uint256[](1);
        ids[0] = pid;
        amts[0] = amt;
        vm.prank(_a(s));
        try fr.back{value: amt}(rid, ids, amts) {} catch {}
    }

    function topUp(uint256 s, uint256 amt) external {
        amt = bound(amt, 1, 1 ether);
        vm.prank(_a(s));
        try fr.topUpPool{value: amt}(rid) {} catch {}
    }

    function delist(uint256 pid) external {
        vm.prank(steward);
        try fr.delistProject(rid, bound(pid, 0, 4), "x") {} catch {}
    }

    function cancel(uint256 s) external {
        if (s % 20 != 0) return; // rare
        vm.prank(steward);
        try fr.cancelRound(rid, "x") {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 3 days));
    }

    function finalise() external {
        try fr.finalise(rid) {} catch {}
    }

    function claim(uint256 pid) external {
        pid = bound(pid, 0, 4);
        address w = fr.getProject(rid, pid).wallet;
        vm.prank(w);
        try fr.claim(rid, pid) {} catch {}
    }

    function refund(uint256 s, uint256 pid) external {
        vm.prank(_a(s));
        try fr.refund(rid, bound(pid, 0, 4)) {} catch {}
    }

    function withdraw(uint256 s) external {
        vm.prank(s % 3 == 0 ? steward : _a(s));
        try fr.withdrawPool(rid) {} catch {}
    }

    function breakRegistry(bool b) external {
        reg.setBroken(b);
    }

    /// What the contract still owes, computed from its public state.
    function owed() external view returns (uint256 o) {
        FundingRounds.Round memory r = fr.getRound(rid);
        uint256 n = fr.projectCount(rid);
        for (uint256 pid; pid < n; ++pid) {
            FundingRounds.Project memory p = fr.getProject(rid, pid);
            if (r.cancelled || p.status == FundingRounds.Status.Delisted) {
                for (uint256 i; i < actors.length; ++i) o += fr.paidByWallet(rid, pid, actors[i]);
            } else if (!p.claimed) {
                o += p.raised + p.matched;
            }
        }
        uint256 unused = r.cancelled ? r.pool : (r.finalised ? r.pool - r.matchedTotal : r.pool);
        if (r.finalised || r.cancelled) {
            uint256 left;
            if (!fr.poolWithdrawn(rid, steward)) left += fr.poolFundedBy(rid, steward);
            for (uint256 i; i < actors.length; ++i) {
                if (!fr.poolWithdrawn(rid, actors[i])) left += fr.poolFundedBy(rid, actors[i]);
            }
            o += (left * unused) / r.pool;
        } else {
            o += unused;
        }
    }
}

contract FundingRoundsInvariantTest is Test {
    FundingRounds fr;
    MockAgentID reg;
    Handler h;

    function setUp() public {
        vm.warp(1_790_000_000);
        reg = new MockAgentID();
        fr = new FundingRounds(IAgentID(address(reg)));
        address steward = makeAddr("steward");
        reg.give(steward, "steward");
        vm.deal(steward, 10 ether);
        uint64 start = uint64(block.timestamp);
        uint64 end = uint64(block.timestamp + 5 days);
        vm.prank(steward);
        uint256 rid = fr.createRound{value: 1 ether}("Inv", start, end, 0.001 ether, 0.02 ether, 3000);
        for (uint256 i; i < 5; ++i) {
            address b = address(uint160(0xC000 + i));
            reg.give(b, string.concat("builder", vm.toString(i)));
            vm.prank(b);
            fr.applyProject(rid, "P", "");
            vm.prank(steward);
            fr.approveProject(rid, i);
        }
        h = new Handler(fr, reg, steward, rid, end);
        for (uint256 i; i < 12; ++i) reg.give(address(uint160(0xA000 + i)), string.concat("actor", vm.toString(i)));
        targetContract(address(h));
    }

    /// The contract never owes more than it holds.
    function invariant_solvent() public view {
        assertGe(address(fr).balance, h.owed());
    }

    /// Matching never exceeds the pool.
    function invariant_matchWithinPool() public view {
        FundingRounds.Round memory r = fr.getRound(0);
        assertLe(r.matchedTotal, r.pool);
    }
}
