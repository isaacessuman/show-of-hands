// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC8004Identity} from "../Attestor.sol";
import {IERC8004ReputationFull} from "./IERC8004Full.sol";

/// @title LiveScore
/// @notice Keeps exactly ONE live ERC-8004 feedback entry per voice: a lifetime score. Each time the score changes
///         the previous entry is revoked and a new one is written, so `getSummary` over this client always sees one
///         number per person. Cutting a record into many small attestations can no longer add weight.
/// @dev    Registry calls are wrapped in try/catch: a broken or upgraded third-party registry can delay publishing
///         but can never block scoring, and `publish(voice)` retries at any time.
abstract contract LiveScore {
    IERC8004Identity public immutable IDENTITY;
    IERC8004ReputationFull public immutable REPUTATION;

    struct Score {
        uint32 counted; // scored items the voice took part in
        uint32 hits; // of those, how many the voice got right
    }

    struct Live {
        uint256 agentId;
        uint64 index; // 0 = nothing live
    }

    /// @notice voice => lifetime score.
    mapping(bytes32 voice => Score) public scoreOf;
    /// @notice voice => the one live feedback entry this contract wrote for it.
    mapping(bytes32 voice => Live) public liveOf;

    event Published(bytes32 indexed voice, uint256 indexed agentId, uint64 index, uint32 counted, uint32 hits);
    event Withdrawn(bytes32 indexed voice, uint256 indexed agentId, uint64 index);
    event PublishFailed(bytes32 indexed voice, uint256 indexed agentId);
    event WithdrawFailed(bytes32 indexed voice, uint256 indexed agentId, uint64 index);

    /// @notice Gas that must be left before any registry write, so a caller cannot make a write fail on purpose by
    ///         sending too little gas (try/catch would otherwise swallow the out-of-gas).
    uint256 public constant REGISTRY_WRITE_GAS = 400_000;

    error NeedMoreGas();

    constructor(IERC8004Identity identity, IERC8004ReputationFull reputation) {
        IDENTITY = identity;
        REPUTATION = reputation;
    }

    /// @notice Anyone may (re)write a voice's live entry from its current lifetime score and link. Safe to repeat.
    function publish(bytes32 voice) public {
        _publish(voice);
    }

    /// @dev Where a voice's score should go: (agentId, owner at link time). owner == 0 means not linked.
    function _linkOf(bytes32 voice) internal view virtual returns (uint256 agentId, address owner);
    function _tag() internal pure virtual returns (string memory);
    function _source() internal pure virtual returns (string memory);
    function _endpoint() internal pure virtual returns (string memory);

    function _publish(bytes32 voice) internal {
        Score memory s = scoreOf[voice];
        (uint256 agentId, address owner) = _linkOf(voice);
        if (!_withdraw(voice)) return; // never risk two live entries
        if (s.counted == 0 || owner == address(0) || !_ownerIs(agentId, owner)) return;

        if (gasleft() < REGISTRY_WRITE_GAS) revert NeedMoreGas();
        bytes32 hash = keccak256(abi.encode(block.chainid, address(this), voice, agentId, s.counted, s.hits));
        try REPUTATION.giveFeedback(
            agentId, int128(uint128(uint256(s.hits) * 100 / s.counted)), 0, _tag(), _source(), _endpoint(), "", hash
        ) {
            uint64 index = REPUTATION.getLastIndex(agentId, address(this));
            liveOf[voice] = Live(agentId, index);
            emit Published(voice, agentId, index, s.counted, s.hits);
        } catch {
            emit PublishFailed(voice, agentId);
        }
    }

    /// @dev Revoke the voice's live entry, if any. Returns false (and keeps the record) if the registry refused, so
    ///      a new entry is only written once the old one is really gone.
    function _withdraw(bytes32 voice) internal returns (bool) {
        Live memory l = liveOf[voice];
        if (l.index == 0) return true;
        if (gasleft() < REGISTRY_WRITE_GAS) revert NeedMoreGas();
        try REPUTATION.revokeFeedback(l.agentId, l.index) {
            delete liveOf[voice];
            emit Withdrawn(voice, l.agentId, l.index);
            return true;
        } catch {
            emit WithdrawFailed(voice, l.agentId, l.index);
            return false;
        }
    }

    function _ownerIs(uint256 agentId, address who) internal view returns (bool) {
        try IDENTITY.ownerOf(agentId) returns (address o) {
            return o == who;
        } catch {
            return false;
        }
    }
}
