// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Polls} from "../src/Polls.sol";
import {CrowdScoreV2} from "../src/CrowdScoreV2.sol";
import {PredictionsV2} from "../src/PredictionsV2.sol";
import {Predictions, IPriceFeed} from "../src/Predictions.sol";
import {IERC8004Identity} from "../src/Attestor.sol";
import {IERC8004ReputationFull} from "../src/lib/IERC8004Full.sol";
import {IAgentID} from "../src/lib/OneVoice.sol";
import {IIdentityFull, IReputationFull} from "./CrowdScoreFork.t.sol";

/// v2 against live BNB Smart Chain: the deployed Polls, real Agent ID holders, the real ERC-8004 registries (with
/// their real revoke rules) and the real Chainlink feeds. Set BSC_RPC_URL to run; skipped otherwise.
contract V2ForkTest is Test {
    IAgentID constant AGENT_ID = IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);
    IIdentityFull constant IDENTITY = IIdentityFull(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    IReputationFull constant REPUTATION = IReputationFull(0x8004BAa17C55a88189AE136b182e5fdA19dE9b63);
    Polls constant LIVE_POLLS = Polls(0x0EB39713C32f9Cf6f9120818E14a101D35aa2aC4);
    Predictions constant PRED_V1 = Predictions(0x77a23A374729B6482Bc7034cFFC3c78f96869c8a);
    address constant BNB = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address constant BTC = 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf;
    address constant ETH = 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e;

    address[] h;
    Polls polls;
    CrowdScoreV2 cs;
    PredictionsV2 pr;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        h.push(0xF1EDff5946c4672b06cDfF912951ba76C925bAc5);
        h.push(0xbB78808Da219b090BE86D7aAb253C3E6832C6115);
        h.push(0xA8f1965E501fA320b14C7CF4DFC7bCd291B87131);
        h.push(0xd626673eb9D1637D0b2c7aad802215986b03F177);
        h.push(0xF5C9791fbD8F740775850f7aF5c0DF94d24541e4);
        h.push(0x41acb48Ea3b345b6aD64e2B564dc786DEe60CC44);
        h.push(0x13E488c542DA4D1665A5bBddB8633C2F206B7e3D);
        h.push(0x12faa2440ee4170c6613Db635afbab1963fCdE36);
        polls = new Polls(AGENT_ID);
        cs = new CrowdScoreV2(polls, IERC8004Identity(address(IDENTITY)), IERC8004ReputationFull(address(REPUTATION)));
        IPriceFeed[3] memory f = [IPriceFeed(BNB), IPriceFeed(BTC), IPriceFeed(ETH)];
        pr = new PredictionsV2(
            AGENT_ID, f, cs, IERC8004Identity(address(IDENTITY)), IERC8004ReputationFull(address(REPUTATION))
        );
    }

    function _poll(address creator, bool h1WithCrowd) internal {
        string[] memory o = new string[](2);
        (o[0], o[1]) = ("Yes", "No");
        vm.prank(creator);
        uint256 id = polls.createPoll("Fork poll?", o, uint64(vm.getBlockTimestamp() + 1 hours));
        for (uint256 i = 1; i < 7; ++i) {
            vm.prank(h[i]);
            polls.vote(id, i == 1 ? (h1WithCrowd ? 0 : 1) : (i < 6 ? 0 : 1)); // crowd: 5-1 or 4-2 for Yes
        }
        vm.warp(vm.getBlockTimestamp() + 1 hours);
    }

    /// The v1 inflation fix on the real registry: three attestations, one live entry, real revokes.
    function test_oneLiveEntryOnRealRegistry() public {
        bytes32 voice = polls.voiceOf(h[1]);
        vm.prank(h[1]);
        uint256 agentId = IDENTITY.register("https://example.org/agent.json");
        vm.prank(h[1]);
        uint256 g = gasleft();
        cs.link(agentId);
        emit log_named_uint("link gas (nothing to publish)", g - gasleft());

        _poll(h[0], true);
        g = gasleft();
        cs.attest(voice);
        emit log_named_uint("attest gas, first write", g - gasleft());
        _poll(h[7], true);
        g = gasleft();
        cs.attest(voice);
        emit log_named_uint("attest gas, revoke + write", g - gasleft());
        _poll(h[0], false);
        cs.attest(voice);

        assertEq(REPUTATION.getLastIndex(agentId, address(cs)), 3);
        (,,,, bool r1) = REPUTATION.readFeedback(agentId, address(cs), 1);
        (,,,, bool r2) = REPUTATION.readFeedback(agentId, address(cs), 2);
        (int128 v3,,,, bool r3) = REPUTATION.readFeedback(agentId, address(cs), 3);
        assertTrue(r1 && r2 && !r3);
        assertEq(v3, 66);

        address[] memory clients = new address[](1);
        clients[0] = address(cs);
        (uint64 count, int128 avg,) = REPUTATION.getSummary(agentId, clients, "crowd-accuracy", "showofhands");
        assertEq(count, 1);
        assertEq(avg, 66);
    }

    /// Reads the live Polls contract: the scan stops at open polls and never reverts on real data.
    function test_previewOnLivePolls() public {
        CrowdScoreV2 live = new CrowdScoreV2(
            LIVE_POLLS, IERC8004Identity(address(IDENTITY)), IERC8004ReputationFull(address(REPUTATION))
        );
        (uint256 from, uint256 to, uint32 counted, uint32 matched) = live.preview(LIVE_POLLS.voiceOf(h[0]));
        emit log_named_uint("live polls scanned", to - from);
        emit log_named_uint("counted", counted);
        emit log_named_uint("matched", matched);
        assertEq(from, 0);
        assertLe(to, LIVE_POLLS.pollCount());
    }

    /// settleArgs on the real feeds agrees with v1's firstRoundAfter, and settle accepts it.
    function test_realFeedsSettle() public {
        uint256 realNow = vm.getBlockTimestamp();
        for (uint8 asset; asset < 3; ++asset) {
            uint64 T = uint64(realNow - 2 days);
            uint256 g = gasleft();
            (uint80 r, uint80 ph, uint80 nh) = pr.settleArgs(asset, T);
            emit log_named_uint("settleArgs gas", g - gasleft());
            emit log_named_uint("round phase", uint256(r >> 64));
            assertGt(r, 0);
            assertEq(nh, 0); // current phase
            uint80 v1 = PRED_V1.firstRoundAfter(asset, T);
            if (v1 != 0) assertEq(r, v1);
            (, int256 p,, uint256 t,) = IPriceFeed([BNB, BTC, ETH][asset]).getRoundData(r);
            assertGe(t, T);
            assertGt(p, 0);
            ph;
        }

        vm.warp(realNow - 3 days);
        uint64 ends = uint64(realNow - 3 days + 2 hours);
        uint64 checkAt = uint64(realNow - 2 days);
        vm.prank(h[0]);
        uint256 id = pr.create(0, 1, ends, checkAt);
        vm.prank(h[1]);
        pr.vote(id, true);
        vm.warp(realNow);
        (uint80 r0, uint80 ph0, uint80 nh0) = pr.settleArgs(0, checkAt);
        uint256 g2 = gasleft();
        pr.settle(id, r0, ph0, nh0);
        emit log_named_uint("settle gas", g2 - gasleft());
        assertEq(uint8(pr.getPrediction(id).outcome), uint8(PredictionsV2.Outcome.Above)); // strike $0.00000001

        // h[1] links a record in CrowdScoreV2 and gets a prediction-accuracy entry
        vm.prank(h[1]);
        uint256 agentId = IDENTITY.register("https://example.org/agent.json");
        vm.prank(h[1]);
        cs.link(agentId);
        pr.attest(polls.voiceOf(h[1]));
        (int128 val,, string memory t1,, bool revoked) = REPUTATION.readFeedback(agentId, address(pr), 1);
        assertEq(val, 100);
        assertEq(t1, "prediction-accuracy");
        assertFalse(revoked);
    }
}
