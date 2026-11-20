// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Polls} from "../src/Polls.sol";
import {CrowdScoreV2} from "../src/CrowdScoreV2.sol";
import {PredictionsV2} from "../src/PredictionsV2.sol";
import {IPriceFeed} from "../src/Predictions.sol";
import {IERC8004Identity} from "../src/Attestor.sol";
import {IERC8004ReputationFull} from "../src/lib/IERC8004Full.sol";
import {IAgentID} from "../src/lib/OneVoice.sol";

/// Reference deployment. The live one goes through the CREATE2 proxy 0x4e59…956C with salts
/// keccak256("showofhands.jushou.v1.CrowdScoreV2") and keccak256("showofhands.jushou.v1.PredictionsV2"),
/// giving CrowdScoreV2 0xA43Fa81D92c9229A9883379f943Ad6E170a9003E and PredictionsV2 0x27299aBe7c2226b95CCA017ee0A2210F2f8D5C92.
contract DeployV2 is Script {
    function run() external {
        require(block.chainid == 56, "BSC mainnet only");
        IERC8004Identity id = IERC8004Identity(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
        IERC8004ReputationFull rep = IERC8004ReputationFull(0x8004BAa17C55a88189AE136b182e5fdA19dE9b63);
        IPriceFeed[3] memory f = [
            IPriceFeed(0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE), // BNB/USD
            IPriceFeed(0x264990fbd0A4796A3E3d8E37C4d5F87a3aCa5Ebf), // BTC/USD
            IPriceFeed(0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e) // ETH/USD
        ];
        vm.startBroadcast();
        CrowdScoreV2 cs = new CrowdScoreV2(Polls(0x0EB39713C32f9Cf6f9120818E14a101D35aa2aC4), id, rep);
        PredictionsV2 pr = new PredictionsV2(IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F), f, cs, id, rep);
        vm.stopBroadcast();
        console.log("CrowdScoreV2", address(cs));
        console.log("PredictionsV2", address(pr));
    }
}
