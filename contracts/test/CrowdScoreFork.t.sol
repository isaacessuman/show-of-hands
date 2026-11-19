// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Polls} from "../src/Polls.sol";
import {CrowdScore} from "../src/CrowdScore.sol";
import {IERC8004Identity, IERC8004Reputation} from "../src/Attestor.sol";
import {IAgentID} from "../src/lib/OneVoice.sol";

interface IIdentityFull {
    function register(string calldata agentURI) external returns (uint256 agentId);
    function ownerOf(uint256 agentId) external view returns (address);
    function setApprovalForAll(address operator, bool approved) external;
    function transferFrom(address from, address to, uint256 agentId) external;
}

interface IReputationFull {
    function getSummary(
        uint256 agentId,
        address[] calldata clients,
        string calldata tag1,
        string calldata tag2
    ) external view returns (uint64 count, int128 value, uint8 decimals);
    function readFeedback(uint256 agentId, address client, uint64 index)
        external
        view
        returns (int128 value, uint8 valueDecimals, string memory tag1, string memory tag2, bool isRevoked);
    function getLastIndex(uint256 agentId, address client) external view returns (uint64);
}

/// CrowdScore against a copy of live BNB Smart Chain: the real Agent ID registry and holders, and the real ERC-8004
/// identity and reputation registries. Set BSC_RPC_URL to run; skipped otherwise.
contract CrowdScoreForkTest is Test {
    IAgentID constant AGENT_ID = IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);
    IIdentityFull constant IDENTITY = IIdentityFull(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    IReputationFull constant REPUTATION = IReputationFull(0x8004BAa17C55a88189AE136b182e5fdA19dE9b63);

    address[] h; // real Agent ID holders (same set as test/Fork.t.sol)
    Polls polls;
    CrowdScore cs;
    uint256 agentId;
    bytes32 voice;

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
        cs = new CrowdScore(
            polls, IERC8004Identity(address(IDENTITY)), IERC8004Reputation(address(REPUTATION))
        );
        voice = polls.voiceOf(h[1]);
        assertTrue(voice != bytes32(0));

        // h[1] opens its own ERC-8004 agent record: registration is open to any address
        vm.prank(h[1]);
        agentId = IDENTITY.register("https://example.org/agent.json");
        assertEq(IDENTITY.ownerOf(agentId), h[1]);

        // two polls, 9 real voters each; h[1] votes with the crowd in poll 0 and against it in poll 1
        string[] memory o = new string[](2);
        o[0] = "Yes";
        o[1] = "No";
        vm.prank(h[0]);
        polls.createPoll("Fork poll A?", o, uint64(block.timestamp + 1 days));
        vm.prank(h[2]);
        polls.createPoll("Fork poll B?", o, uint64(block.timestamp + 1 days));
        for (uint256 i = 1; i < h.length; ++i) {
            vm.prank(h[i]);
            polls.vote(0, i < 7 ? 0 : 1); // 6-3 for "Yes"; h[1] voted "Yes"
            vm.prank(h[i]);
            polls.vote(1, i == 1 || i > 6 ? 1 : 0); // 5-4 for "Yes"; h[1] voted "No"
        }
        vm.warp(block.timestamp + 1 days);
    }

    function test_attestWritesToRealReputationRegistry() public {
        vm.prank(h[1]);
        uint256 g = gasleft();
        cs.link(agentId);
        emit log_named_uint("link gas on live registries", g - gasleft());

        (uint256 from, uint256 to, uint32 counted, uint32 matched) = cs.preview(voice, 2);
        assertEq(from, 0);
        assertEq(to, 2);
        assertEq(counted, 2);
        assertEq(matched, 1);

        vm.prank(address(0xBEEF)); // a stranger triggers it
        g = gasleft();
        cs.attest(voice, 2);
        emit log_named_uint("attest gas on live registries (2 voted polls)", g - gasleft());

        // the real registry accepted CrowdScore as the feedback client
        assertEq(REPUTATION.getLastIndex(agentId, address(cs)), 1);
        (int128 value, uint8 dec, string memory t1, string memory t2, bool revoked) =
            REPUTATION.readFeedback(agentId, address(cs), 1);
        assertEq(value, 50);
        assertEq(dec, 0);
        assertEq(t1, "crowd-accuracy");
        assertEq(t2, "showofhands");
        assertFalse(revoked);

        address[] memory clients = new address[](1);
        clients[0] = address(cs);
        (uint64 count, int128 avg,) = REPUTATION.getSummary(agentId, clients, "crowd-accuracy", "showofhands");
        assertEq(count, 1);
        assertEq(avg, 50);
    }

    function test_ownerChangedOnRealRegistry() public {
        vm.prank(h[1]);
        cs.link(agentId);
        vm.prank(h[1]);
        IDENTITY.transferFrom(h[1], address(0xCAFE), agentId); // records are ordinary transferable ERC-721s
        vm.expectRevert(CrowdScore.OwnerChanged.selector);
        cs.attest(voice, 2);
    }

    function test_realRegistryRejectsIfCrowdScoreIsOperator() public {
        // The registry blocks "self-feedback" from the owner or any approved operator. If a record owner approves
        // CrowdScore as an operator, its own attestations revert; this harms nobody else.
        vm.prank(h[1]);
        cs.link(agentId);
        vm.prank(h[1]);
        IDENTITY.setApprovalForAll(address(cs), true);
        vm.expectRevert(bytes("Self-feedback not allowed"));
        cs.attest(voice, 2);
    }
}
