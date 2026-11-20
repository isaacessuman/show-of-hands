// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev ERC-8004 identity: an owner per agent id, reverting for unknown ids like ERC-721 does.
contract MockIdentity2 {
    mapping(uint256 => address) public owners;

    function setOwner(uint256 agentId, address who) external {
        owners[agentId] = who;
    }

    function ownerOf(uint256 agentId) external view returns (address o) {
        o = owners[agentId];
        require(o != address(0), "nonexistent");
    }
}

/// @dev ERC-8004 reputation with the real registry's indexing and revoke rules: indexes are per (agent, client) and
///      start at 1; only the writer may revoke; revoked entries are skipped by `liveCount` / `liveValues`.
contract MockReputation2 {
    struct Entry {
        int128 value;
        uint8 decimals;
        string tag1;
        string tag2;
        bytes32 hash;
        bool revoked;
    }

    mapping(uint256 => mapping(address => Entry[])) internal _e;
    bool public brokenGive;
    bool public brokenRevoke;

    function setBroken(bool give, bool revoke) external {
        (brokenGive, brokenRevoke) = (give, revoke);
    }

    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata,
        string calldata,
        bytes32 feedbackHash
    ) external {
        require(!brokenGive, "give broken");
        require(valueDecimals <= 18, "decimals");
        _e[agentId][msg.sender].push(Entry(value, valueDecimals, tag1, tag2, feedbackHash, false));
    }

    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external {
        require(!brokenRevoke, "revoke broken");
        require(feedbackIndex > 0 && feedbackIndex <= _e[agentId][msg.sender].length, "index");
        Entry storage x = _e[agentId][msg.sender][feedbackIndex - 1];
        require(!x.revoked, "Already revoked");
        x.revoked = true;
    }

    function getLastIndex(uint256 agentId, address client) external view returns (uint64) {
        return uint64(_e[agentId][client].length);
    }

    function entry(uint256 agentId, address client, uint64 index) external view returns (Entry memory) {
        return _e[agentId][client][index - 1];
    }

    /// Live (unrevoked) entries from `client` for `agentId`, and their values.
    function live(uint256 agentId, address client) external view returns (int128[] memory vals) {
        Entry[] storage a = _e[agentId][client];
        uint256 n;
        for (uint256 i; i < a.length; ++i) {
            if (!a[i].revoked) ++n;
        }
        vals = new int128[](n);
        n = 0;
        for (uint256 i; i < a.length; ++i) {
            if (!a[i].revoked) vals[n++] = a[i].value;
        }
    }
}
