// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FundingRounds} from "./FundingRounds.sol";

interface IERC8004Identity {
    function ownerOf(uint256 agentId) external view returns (address);
}

interface IERC8004Reputation {
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;
}

/// @title Show of Hands — Attestor (Agent ID → ERC-8004 bridge)
/// @notice After a funding round settles, writes "backed by N Agent IDs" into the ERC-8004 Reputation Registry for
///         each project that linked its ERC-8004 agent record. Each count rests on settled BNB payments and counts
///         one voice per Agent ID, so it cannot be inflated by spinning up wallets.
/// @dev    Holds no money and has no owner. Kept separate from FundingRounds on purpose: the ERC-8004 registries are
///         upgradeable contracts run by a third party, so nothing about funds may depend on them.
contract Attestor {
    FundingRounds public immutable ROUNDS;
    IERC8004Identity public immutable IDENTITY;
    IERC8004Reputation public immutable REPUTATION;

    string public constant TAG_BACKERS = "agentid-backers";

    struct Link {
        uint256 agentId;
        address owner; // ERC-8004 record owner at link time (must equal the project wallet)
        bool linked;
        bool attested;
    }

    mapping(uint256 roundId => mapping(uint256 projectId => Link)) public links;

    event Linked(uint256 indexed roundId, uint256 indexed projectId, uint256 indexed agentId, address owner);
    event Attested(
        uint256 indexed roundId, uint256 indexed projectId, uint256 indexed agentId, uint32 backers, bytes32 hash
    );

    error NotProjectWallet();
    error NotAgentOwner();
    error AlreadyLinked();
    error NotLinked();
    error AlreadyAttested();
    error NotSettled();
    error OwnerChanged();

    constructor(FundingRounds rounds, IERC8004Identity identity, IERC8004Reputation reputation) {
        ROUNDS = rounds;
        IDENTITY = identity;
        REPUTATION = reputation;
    }

    /// @notice A project's wallet links the project to an ERC-8004 agent record it owns.
    function link(uint256 roundId, uint256 projectId, uint256 agentId) external {
        FundingRounds.Project memory p = ROUNDS.getProject(roundId, projectId);
        if (msg.sender != p.wallet) revert NotProjectWallet();
        if (IDENTITY.ownerOf(agentId) != msg.sender) revert NotAgentOwner();
        Link storage l = links[roundId][projectId];
        if (l.linked) revert AlreadyLinked();
        l.agentId = agentId;
        l.owner = msg.sender;
        l.linked = true;
        emit Linked(roundId, projectId, agentId, msg.sender);
    }

    /// @notice Anyone may write the settled backer count once the round is finalised. Skips (reverts) if the
    ///         ERC-8004 record has changed hands since it was linked, because reputation there moves with the token.
    function attest(uint256 roundId, uint256 projectId) external {
        Link storage l = links[roundId][projectId];
        if (!l.linked) revert NotLinked();
        if (l.attested) revert AlreadyAttested();
        if (!ROUNDS.getRound(roundId).finalised) revert NotSettled();
        FundingRounds.Project memory p = ROUNDS.getProject(roundId, projectId);
        if (p.status != FundingRounds.Status.Approved) revert NotSettled();
        if (IDENTITY.ownerOf(l.agentId) != l.owner) revert OwnerChanged();

        l.attested = true;
        bytes32 hash = keccak256(abi.encode(block.chainid, address(ROUNDS), roundId, projectId, p.backers, p.raised));
        emit Attested(roundId, projectId, l.agentId, p.backers, hash);
        REPUTATION.giveFeedback(
            l.agentId, int128(uint128(p.backers)), 0, TAG_BACKERS, _roundTag(roundId), "", "", hash
        );
    }

    function _roundTag(uint256 roundId) private pure returns (string memory) {
        return string.concat("round-", _toString(roundId));
    }

    function _toString(uint256 v) private pure returns (string memory s) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 t = v; t != 0; t /= 10) ++len;
        bytes memory b = new bytes(len);
        for (; v != 0; v /= 10) b[--len] = bytes1(uint8(48 + (v % 10)));
        s = string(b);
    }
}
