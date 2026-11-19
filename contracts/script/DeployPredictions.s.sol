// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Predictions, IPriceFeed} from "../src/Predictions.sol";
import {CrowdScore} from "../src/CrowdScore.sol";
import {IERC8004Identity, IERC8004Reputation} from "../src/Attestor.sol";
import {IAgentID} from "../src/lib/OneVoice.sol";

/// Reference deployment (the live one went through the CREATE2 proxy with salt keccak256("showofhands.jushou.v1.Predictions")).
contract DeployPredictions is Script {
    function run() external {
        require(block.chainid == 56, "BSC mainnet only");
        IPriceFeed[3] memory f = [
            IPriceFeed(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE), // BNB/USD
            IPriceFeed(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf), // BTC/USD
            IPriceFeed(0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e) // ETH/USD
        ];
        vm.startBroadcast();
        Predictions p = new Predictions(
            IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F),
            f,
            CrowdScore(0x1a912bc6d6fA8E3a3E9Eb28ff31B6bF1610Ecff3),
            IERC8004Identity(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            IERC8004Reputation(0x8004BAa17C55a88189AE136b182e5fdA19dE9b63)
        );
        vm.stopBroadcast();
        console.log("Predictions", address(p));
    }
}
