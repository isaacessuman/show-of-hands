// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Polls} from "../src/Polls.sol";
import {FundingRounds} from "../src/FundingRounds.sol";
import {Attestor, IERC8004Identity, IERC8004Reputation} from "../src/Attestor.sol";
import {IAgentID} from "../src/lib/OneVoice.sol";

/// forge script script/Deploy.s.sol --rpc-url bsc --broadcast --verify   (signer chosen at run time, e.g. --ledger)
contract Deploy is Script {
    IAgentID constant AGENT_ID = IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);
    address constant ERC8004_IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address constant ERC8004_REPUTATION = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;

    function run() external {
        require(block.chainid == 56, "BSC mainnet only");
        vm.startBroadcast();
        Polls polls = new Polls(AGENT_ID);
        FundingRounds rounds = new FundingRounds(AGENT_ID);
        Attestor att =
            new Attestor(rounds, IERC8004Identity(ERC8004_IDENTITY), IERC8004Reputation(ERC8004_REPUTATION));
        vm.stopBroadcast();
        console.log("Polls        ", address(polls));
        console.log("FundingRounds", address(rounds));
        console.log("Attestor     ", address(att));
    }
}
