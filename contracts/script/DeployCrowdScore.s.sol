// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Polls} from "../src/Polls.sol";
import {CrowdScore} from "../src/CrowdScore.sol";
import {IERC8004Identity, IERC8004Reputation} from "../src/Attestor.sol";

/// forge script script/DeployCrowdScore.s.sol --rpc-url bsc --broadcast --verify   (signer chosen at run time)
contract DeployCrowdScore is Script {
    Polls constant POLLS = Polls(0x0EB39713C32f9Cf6f9120818E14a101D35aa2aC4);
    address constant ERC8004_IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    address constant ERC8004_REPUTATION = 0x8004BAa17C55a88189AE136b182e5fdA19dE9b63;

    function run() external {
        require(block.chainid == 56, "BSC mainnet only");
        require(address(POLLS).code.length > 0, "Polls not found");
        vm.startBroadcast();
        CrowdScore cs =
            new CrowdScore(POLLS, IERC8004Identity(ERC8004_IDENTITY), IERC8004Reputation(ERC8004_REPUTATION));
        vm.stopBroadcast();
        console.log("CrowdScore", address(cs));
    }
}
