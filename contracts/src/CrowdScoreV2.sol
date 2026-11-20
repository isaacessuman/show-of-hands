// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Polls} from "./Polls.sol";
import {IERC8004Identity} from "./Attestor.sol";
import {IERC8004ReputationFull} from "./lib/IERC8004Full.sol";
import {LiveScore} from "./lib/LiveScore.sol";

/// @title Show of Hands — CrowdScore v2 (voting record → one live ERC-8004 score per person)
/// @notice Writes "how often this Agent ID voted with the crowd's final answer" into the ERC-8004 Reputation
///         Registry, computed on-chain from Polls and nothing else.
///         A poll is FINAL when it has closed, has at least QUORUM votes, and exactly one option has the highest
///         tally. The score is LIFETIME: matched * 100 / counted over every final poll the voice voted in, scanned
///         in order from poll 0. Each voice has exactly one live feedback entry; when the score changes the old
///         entry is revoked and a new one written. So the score cannot be inflated by splitting the record into
///         many small attestations, and a voter cannot skip polls they got wrong.
///         v1 (0x1a91…cff3) let the caller choose batch boundaries, and each batch added a separate entry.
/// @dev    Holds no money, has no owner, no admin and no upgrade path. Anyone may call `attest` and `publish`.
contract CrowdScoreV2 is LiveScore {
    Polls public immutable POLLS;

    /// @notice Minimum votes for a closed poll to count (matches DEFAULT_QUORUM in verdict.js).
    uint256 public constant QUORUM = 5;
    /// @notice Most polls one `attest` call may scan, so a call always fits in a block.
    uint256 public constant MAX_SCAN = 100;

    string public constant TAG_ACCURACY = "crowd-accuracy";
    string public constant TAG_SOURCE = "showofhands";
    string public constant ENDPOINT = "https://showofhands.io/#/league";

    struct Link {
        uint256 agentId;
        address owner; // ERC-8004 record owner at link time; zero means "not linked"
    }

    /// @notice voice => the ERC-8004 agent record that receives this voice's scores (also used by PredictionsV2).
    mapping(bytes32 voice => Link) public links;
    /// @notice agentId => the one voice whose scores it carries. A record never carries two people's scores.
    mapping(uint256 agentId => bytes32) public holderOf;
    /// @notice voice => first poll id not yet scanned.
    mapping(bytes32 voice => uint256) public next;

    event Linked(bytes32 indexed voice, uint256 indexed agentId, address indexed owner);
    event Unlinked(bytes32 indexed voice, uint256 indexed agentId);
    event Attested(bytes32 indexed voice, uint256 from, uint256 to, uint32 counted, uint32 matched);

    error NoAgentID();
    error NotAgentOwner();
    error NothingToAttest();

    constructor(Polls polls, IERC8004Identity identity, IERC8004ReputationFull reputation)
        LiveScore(identity, reputation)
    {
        POLLS = polls;
    }

    /// @notice Point the caller's voice at an ERC-8004 agent record the caller owns. Re-linking moves the live score
    ///         to the new record. If another voice held this record, that voice is unlinked and its entry revoked.
    function link(uint256 agentId) external {
        bytes32 voice = POLLS.voiceOf(msg.sender);
        if (voice == bytes32(0)) revert NoAgentID();
        if (!_ownerIs(agentId, msg.sender)) revert NotAgentOwner();

        bytes32 prevHolder = holderOf[agentId];
        if (prevHolder != bytes32(0) && prevHolder != voice) {
            delete links[prevHolder];
            _withdraw(prevHolder);
            emit Unlinked(prevHolder, agentId);
        }
        uint256 oldAgent = links[voice].agentId;
        if (oldAgent != agentId && holderOf[oldAgent] == voice) delete holderOf[oldAgent];

        links[voice] = Link(agentId, msg.sender);
        holderOf[agentId] = voice;
        emit Linked(voice, agentId, msg.sender);
        _publish(voice);
    }

    /// @notice What `attest(voice)` would scan and add right now: polls [from, to), stopping at the first open poll.
    function preview(bytes32 voice) public view returns (uint256 from, uint256 to, uint32 counted, uint32 matched) {
        from = next[voice];
        uint256 end = POLLS.pollCount();
        if (end > from + MAX_SCAN) end = from + MAX_SCAN;
        for (to = from; to < end; ++to) {
            if (POLLS.isOpen(to)) break;
            uint8 choice = POLLS.choiceOf(to, voice); // option + 1; zero = did not vote
            if (choice == 0) continue;
            (,,,, uint32 total,,, uint32[] memory tallies) = POLLS.getPoll(to);
            (bool isFinal, uint256 winner) = _winner(total, tallies);
            if (!isFinal) continue;
            ++counted;
            if (choice - 1 == winner) ++matched;
        }
    }

    /// @notice Anyone may bring a voice's lifetime score up to date: scans closed polls in order from where the last
    ///         call stopped (up to MAX_SCAN, stopping at the first open poll) and rewrites the live entry if it changed.
    function attest(bytes32 voice) external {
        (uint256 from, uint256 to, uint32 counted, uint32 matched) = preview(voice);
        if (to == from) revert NothingToAttest();
        next[voice] = to;
        emit Attested(voice, from, to, counted, matched);
        if (counted == 0) return;
        Score storage s = scoreOf[voice];
        s.counted += counted;
        s.hits += matched;
        _publish(voice);
    }

    function _linkOf(bytes32 voice) internal view override returns (uint256, address) {
        Link memory l = links[voice];
        return (l.agentId, l.owner);
    }

    function _tag() internal pure override returns (string memory) {
        return TAG_ACCURACY;
    }

    function _source() internal pure override returns (string memory) {
        return TAG_SOURCE;
    }

    function _endpoint() internal pure override returns (string memory) {
        return ENDPOINT;
    }

    /// @dev A closed poll is final with quorum and a single top option (> 0 votes). Returns that option.
    function _winner(uint32 total, uint32[] memory tallies) private pure returns (bool, uint256 winner) {
        if (total < QUORUM) return (false, 0);
        uint32 top;
        bool tied;
        for (uint256 i; i < tallies.length; ++i) {
            if (tallies[i] > top) {
                top = tallies[i];
                winner = i;
                tied = false;
            } else if (tallies[i] == top) {
                tied = true;
            }
        }
        return (top > 0 && !tied, winner);
    }
}
