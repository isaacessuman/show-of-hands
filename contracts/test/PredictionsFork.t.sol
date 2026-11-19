// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Polls} from "../src/Polls.sol";
import {CrowdScore} from "../src/CrowdScore.sol";
import {Predictions, IPriceFeed} from "../src/Predictions.sol";
import {IERC8004Identity, IERC8004Reputation} from "../src/Attestor.sol";
import {IAgentID} from "../src/lib/OneVoice.sol";
import {IIdentityFull, IReputationFull} from "./CrowdScoreFork.t.sol";

/// Predictions against live BNB Smart Chain: the real Chainlink BNB/BTC/ETH feeds, the real Agent ID registry and
/// holders, the deployed CrowdScore and the real ERC-8004 registries. Set BSC_RPC_URL to run; skipped otherwise.
contract PredictionsForkTest is Test {
    IAgentID constant AGENT_ID = IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);
    IIdentityFull constant IDENTITY = IIdentityFull(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    IReputationFull constant REPUTATION = IReputationFull(0x8004BAa17C55a88189AE136b182e5fdA19dE9b63);
    CrowdScore constant CS = CrowdScore(0x1a912bc6d6fA8E3a3E9Eb28ff31B6bF1610Ecff3);
    address constant BNB = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address constant BTC = 0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf;
    address constant ETH = 0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e;

    address[] h;
    Predictions pr;

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
        IPriceFeed[3] memory f = [IPriceFeed(BNB), IPriceFeed(BTC), IPriceFeed(ETH)];
        pr = new Predictions(AGENT_ID, f, CS, IERC8004Identity(address(IDENTITY)), IERC8004Reputation(address(REPUTATION)));
    }

    function test_realFeedsSettleAndWriteERC8004() public {
        uint256 realNow = vm.getBlockTimestamp(); // not block.timestamp: via-ir may re-read it after warp
        (, int256 bnbNow,,,) = IPriceFeed(BNB).latestRoundData();

        // Ask in the past (two days ago) so the real feed already has the answer by "now".
        vm.warp(realNow - 2 days);
        uint64 ends = uint64(block.timestamp + 1 hours);
        uint64 checkAt = ends + 1 hours;
        vm.prank(h[0]);
        uint256 id = pr.create(0, bnbNow, ends, checkAt);
        vm.prank(h[1]);
        pr.vote(id, true);
        vm.prank(h[2]);
        pr.vote(id, false);

        // h[1] links its own ERC-8004 agent through the deployed CrowdScore
        vm.warp(realNow);
        vm.startPrank(h[1]);
        uint256 agentId = IDENTITY.register("https://example.org/agent.json");
        CS.link(agentId);
        vm.stopPrank();

        uint80 r = pr.firstRoundAfter(0, checkAt);
        assertTrue(r != 0, "round found");
        (,,, uint256 tr,) = IPriceFeed(BNB).getRoundData(r);
        (,,, uint256 tp,) = IPriceFeed(BNB).getRoundData(r - 1);
        assertGe(tr, checkAt);
        assertLt(tp, checkAt);
        vm.expectRevert(Predictions.BadRound.selector);
        pr.settle(id, r + 1);
        pr.settle(id, r);
        Predictions.Prediction memory p = pr.getPrediction(id);
        assertTrue(p.outcome != Predictions.Outcome.Pending);
        bool above = p.outcome == Predictions.Outcome.Above;
        emit log_named_int("BNB price at check time (8 dp)", p.settledPrice);

        bytes32 v1 = CS.POLLS().voiceOf(h[1]);
        pr.attest(v1, 1);
        address[] memory clients = new address[](1);
        clients[0] = address(pr);
        (uint64 n, int128 value,) = REPUTATION.getSummary(agentId, clients, "prediction-accuracy", "showofhands");
        assertEq(n, 1);
        assertEq(value, above ? int128(100) : int128(0)); // h[1] said "above"
    }

    function test_realFeedsPriceNow() public view {
        for (uint8 i; i < 3; ++i) {
            (int256 p, uint256 t) = pr.priceNow(i);
            assertGt(p, 0);
            assertGt(t, block.timestamp - 1 days);
        }
    }
}
