// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Polls} from "../src/Polls.sol";
import {FundingRounds} from "../src/FundingRounds.sol";
import {Attestor, IERC8004Identity, IERC8004Reputation} from "../src/Attestor.sol";
import {OneVoice, IAgentID} from "../src/lib/OneVoice.sol";

interface IIdentityRegister {
    function register(string calldata agentURI) external returns (uint256 agentId);
}

interface IReputationRead {
    function getSummary(uint256 agentId, address[] calldata clients, string calldata tag1, string calldata tag2)
        external
        view
        returns (uint64 count, int128 value, uint8 decimals);
}

/// Runs against a copy of live BNB Smart Chain: the real Agent ID registry, real holders, real ERC-8004 registries.
/// Set BSC_RPC_URL to run; skipped otherwise.
contract ForkTest is Test {
    IAgentID constant AGENT_ID = IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);
    address constant ERC8004_IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address constant ERC8004_REPUTATION = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;

    address[] h; // real Agent ID holders seen minting recently
    Polls polls;
    FundingRounds fr;
    Attestor att;

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
        h.push(0xf6AAf510588287eEE4Ed309eeC843655312170E1);
        h.push(0x99f74b5b2BB979a312D9CB26E1f10e5216D670c4);

        polls = new Polls(AGENT_ID);
        fr = new FundingRounds(AGENT_ID);
        att = new Attestor(fr, IERC8004Identity(ERC8004_IDENTITY), IERC8004Reputation(ERC8004_REPUTATION));
        for (uint256 i; i < h.length; ++i) vm.deal(h[i], 1 ether);
    }

    function test_realHoldersHaveVoices() public view {
        for (uint256 i; i < h.length; ++i) {
            bytes32 v = polls.voiceOf(h[i]);
            assertTrue(v != bytes32(0));
            // the voice is the registry's own token id for that name
            assertEq(v, keccak256(bytes(AGENT_ID.handleOf(h[i]))));
        }
        assertEq(polls.voiceOf(address(0xdEaD)), bytes32(0));
    }

    function test_realPollFlowAndGas() public {
        string[] memory o = new string[](2);
        o[0] = "Yes";
        o[1] = "No";
        vm.prank(h[0]);
        uint256 id = polls.createPoll("Fork test?", o, uint64(block.timestamp + 1 days));
        for (uint256 i = 1; i < h.length; ++i) {
            vm.prank(h[i]);
            uint256 g = gasleft();
            polls.vote(id, uint8(i % 2));
            if (i == 1) emit log_named_uint("vote gas on live registry", g - gasleft());
        }
        (,,,, uint32 total,,,) = polls.getPoll(id);
        assertEq(total, h.length - 1);
        vm.prank(h[1]);
        vm.expectRevert(Polls.AlreadyVoted.selector);
        polls.vote(id, 0);
        vm.prank(address(0xdEaD));
        vm.expectRevert(OneVoice.NoAgentID.selector);
        polls.vote(id, 0);
    }

    function test_realRoundAndErc8004Attestation() public {
        uint64 start = uint64(block.timestamp);
        uint64 end = uint64(block.timestamp + 7 days);
        address steward = h[0];
        address builder = h[1];
        vm.prank(steward);
        uint256 rid = fr.createRound{value: 0.1 ether}("Fork round", start, end, 0.001 ether, 0.02 ether, 2000);
        vm.prank(builder);
        fr.applyProject(rid, "Builder", "https://example.org");
        vm.prank(steward);
        fr.approveProject(rid, 0);

        // the builder registers an ERC-8004 agent record and links it
        vm.prank(builder);
        uint256 agentId = IIdentityRegister(ERC8004_IDENTITY).register("https://example.org/agent.json");
        vm.prank(builder);
        att.link(rid, 0, agentId);

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amts = new uint256[](1);
        amts[0] = 0.002 ether;
        for (uint256 i = 2; i < h.length; ++i) {
            vm.prank(h[i]);
            uint256 g = gasleft();
            fr.back{value: 0.002 ether}(rid, ids, amts);
            if (i == 2) emit log_named_uint("first back gas on live registry", g - gasleft());
        }
        assertEq(fr.getProject(rid, 0).backers, h.length - 2);

        vm.warp(end + 24 hours);
        fr.finalise(rid);
        uint256 before = builder.balance;
        vm.prank(builder);
        fr.claim(rid, 0);
        assertEq(builder.balance - before, 0.016 ether + 0.02 ether); // 8 x 0.002 + cap (20% of 0.1)

        att.attest(rid, 0);
        address[] memory clients = new address[](1);
        clients[0] = address(att);
        (uint64 count, int128 value,) =
            IReputationRead(ERC8004_REPUTATION).getSummary(agentId, clients, "agentid-backers", "");
        assertEq(count, 1);
        assertEq(value, int128(int256(h.length - 2)));
        vm.expectRevert(Attestor.AlreadyAttested.selector);
        att.attest(rid, 0);
    }
}
