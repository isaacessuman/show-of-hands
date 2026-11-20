// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC8004Reputation} from "../Attestor.sol";

/// @notice The parts of the ERC-8004 Reputation Registry the v2 scorers use, on top of `giveFeedback`.
///         Feedback indexes are per (agentId, client) and start at 1. Only the client that wrote an entry may
///         revoke it, and `getSummary` skips revoked entries.
interface IERC8004ReputationFull is IERC8004Reputation {
    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external;
    function getLastIndex(uint256 agentId, address clientAddress) external view returns (uint64);
}
