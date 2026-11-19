// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The read-only part of the SPACE ID "Agent ID" registry on BNB Smart Chain
///         (0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F). Agent IDs are soulbound: one per Binance account.
interface IAgentID {
    function balanceOf(address owner) external view returns (uint256);
    function handleOf(address owner) external view returns (string memory);
    function ownerOfHandle(string calldata handle) external view returns (address);
}

/// @title OneVoice
/// @notice Turns a caller into exactly one "voice": the keccak256 hash of their Agent ID name, which is also the
///         registry's own token id for that name. Every action that must count people (vote, back, list, steward)
///         goes through `_voiceOf`. Exits (claims, refunds, withdrawals) never call the registry, so a broken or
///         changed registry can stop new actions but can never lock anyone's money.
abstract contract OneVoice {
    /// @dev Gas ceiling for each registry read, so a misbehaving registry fails cleanly instead of eating all gas.
    uint256 internal constant REGISTRY_READ_GAS = 150_000;
    /// @dev Agent ID names are 3 to 15 characters; anything longer than this is treated as malformed.
    uint256 internal constant MAX_HANDLE_BYTES = 64;

    /// @notice The Agent ID registry. Fixed forever at deployment.
    IAgentID public immutable AGENT_ID;

    error NoAgentID();
    error RegistryUnavailable();

    constructor(IAgentID registry) {
        if (address(registry).code.length == 0) revert RegistryUnavailable();
        AGENT_ID = registry;
    }

    /// @notice The voice of `who`, or bytes32(0) if `who` holds no Agent ID (or the registry cannot answer).
    function voiceOf(address who) public view returns (bytes32) {
        (bool ok, bytes32 voice) = _tryVoiceOf(who);
        return ok ? voice : bytes32(0);
    }

    /// @dev Reverts unless `who` holds an Agent ID whose name points back to `who`.
    function _voiceOf(address who) internal view returns (bytes32 voice) {
        bool ok;
        (ok, voice) = _tryVoiceOf(who);
        if (!ok) {
            if (voice == bytes32(uint256(1))) revert RegistryUnavailable();
            revert NoAgentID();
        }
    }

    /// @dev Returns (true, voice) on success. On failure returns (false, 1) for a registry fault, (false, 0) for
    ///      "no Agent ID".
    function _tryVoiceOf(address who) private view returns (bool, bytes32) {
        address reg = address(AGENT_ID);

        // 1. balanceOf(who) > 0 — the holder check the organisers name.
        (bool ok, bytes memory ret) =
            reg.staticcall{gas: REGISTRY_READ_GAS}(abi.encodeCall(IAgentID.balanceOf, (who)));
        if (!ok || ret.length != 32) return (false, bytes32(uint256(1)));
        if (abi.decode(ret, (uint256)) == 0) return (false, bytes32(0));

        // 2. handleOf(who) — the caller's name.
        (ok, ret) = reg.staticcall{gas: REGISTRY_READ_GAS}(abi.encodeCall(IAgentID.handleOf, (who)));
        if (!ok || ret.length < 64) return (false, bytes32(uint256(1)));
        string memory handle = _decodeString(ret);
        uint256 len = bytes(handle).length;
        if (len == 0) return (false, bytes32(0));
        if (len > MAX_HANDLE_BYTES) return (false, bytes32(uint256(1)));

        // 3. ownerOfHandle(name) == who — the round trip, so a stale or forged name cannot be borrowed.
        (ok, ret) = reg.staticcall{gas: REGISTRY_READ_GAS}(abi.encodeCall(IAgentID.ownerOfHandle, (handle)));
        if (!ok || ret.length != 32) return (false, bytes32(uint256(1)));
        if (abi.decode(ret, (address)) != who) return (false, bytes32(0));

        return (true, keccak256(bytes(handle)));
    }

    /// @dev Bounds-checked decode of an ABI-encoded `string` return value. Malformed data yields "".
    function _decodeString(bytes memory ret) private pure returns (string memory out) {
        uint256 offset;
        uint256 len;
        assembly {
            offset := mload(add(ret, 32))
        }
        if (offset > ret.length - 32) return "";
        assembly {
            len := mload(add(add(ret, 32), offset))
        }
        if (len > MAX_HANDLE_BYTES || offset + 32 + len > ret.length) return "";
        out = new string(len);
        for (uint256 i; i < len; ++i) {
            bytes(out)[i] = ret[offset + 32 + i];
        }
    }
}
