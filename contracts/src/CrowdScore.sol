// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Polls} from "./Polls.sol";
import {IERC8004Identity, IERC8004Reputation} from "./Attestor.sol";

/// @title Show of Hands — CrowdScore (voting record → ERC-8004 reputation)
/// @notice Writes "how often this Agent ID voted with the crowd's final answer" into the ERC-8004 Reputation
///         Registry, computed on-chain from Polls and nothing else.
///         A poll is FINAL when it has closed, has at least QUORUM votes, and exactly one option has the highest
///         tally (the same rule as the site's verdict.js). For each attestation, `counted` is the number of final
///         polls the voice voted in and `matched` is how many of those it voted for the winner; the feedback value
///         is matched * 100 / counted (a whole-number percentage).
///         Polls are scanned as one contiguous range per voice, always starting where the last attestation ended,
///         so a voter cannot pick only the polls they got right: every closed poll is eventually counted, in order.
/// @dev    Holds no money, has no owner, no admin and no upgrade path. Anyone may call `attest`; the result depends
///         only on public Polls state. Kept separate from Polls because the ERC-8004 registries are upgradeable
///         contracts run by a third party.
contract CrowdScore {
    Polls public immutable POLLS;
    IERC8004Identity public immutable IDENTITY;
    IERC8004Reputation public immutable REPUTATION;

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

    /// @notice voice => the ERC-8004 agent record that receives this voice's score.
    mapping(bytes32 voice => Link) public links;
    /// @notice voice => first poll id not yet attested. The next attestation must start here.
    mapping(bytes32 voice => uint256) public next;

    event Linked(bytes32 indexed voice, uint256 indexed agentId, address indexed owner);
    event Attested(
        bytes32 indexed voice,
        uint256 indexed agentId,
        uint256 from,
        uint256 to,
        uint32 counted,
        uint32 matched,
        bytes32 hash
    );

    error NoAgentID();
    error NotAgentOwner();
    error NotLinked();
    error OwnerChanged();
    error EmptyRange();
    error RangeTooLong();
    error NoSuchPoll();
    error PollStillOpen(uint256 pollId);

    constructor(Polls polls, IERC8004Identity identity, IERC8004Reputation reputation) {
        POLLS = polls;
        IDENTITY = identity;
        REPUTATION = reputation;
    }

    /// @notice Point the caller's voice at an ERC-8004 agent record the caller owns. Re-linking replaces the old one.
    function link(uint256 agentId) external {
        bytes32 voice = POLLS.voiceOf(msg.sender);
        if (voice == bytes32(0)) revert NoAgentID();
        if (IDENTITY.ownerOf(agentId) != msg.sender) revert NotAgentOwner();
        links[voice] = Link(agentId, msg.sender);
        emit Linked(voice, agentId, msg.sender);
    }

    /// @notice What `attest(voice, toPollId)` would count right now. Reverts for the same reasons attest would.
    function preview(bytes32 voice, uint256 toPollId)
        public
        view
        returns (uint256 from, uint256 to, uint32 counted, uint32 matched)
    {
        from = next[voice];
        to = toPollId;
        if (to <= from) revert EmptyRange();
        if (to - from > MAX_SCAN) revert RangeTooLong();
        if (to > POLLS.pollCount()) revert NoSuchPoll();

        for (uint256 id = from; id < to; ++id) {
            if (POLLS.isOpen(id)) revert PollStillOpen(id);
            uint8 choice = POLLS.choiceOf(id, voice); // option + 1; zero = did not vote
            if (choice == 0) continue;
            (,,,, uint32 total,,, uint32[] memory tallies) = POLLS.getPoll(id);
            (bool isFinal, uint256 winner) = _winner(total, tallies);
            if (!isFinal) continue;
            ++counted;
            if (choice - 1 == winner) ++matched;
        }
    }

    /// @notice Anyone may attest a voice's record over polls [next[voice], toPollId). Every poll in the range must
    ///         be closed. If the voice voted in at least one final poll, the score is written to its linked record.
    function attest(bytes32 voice, uint256 toPollId) external {
        (uint256 from, uint256 to, uint32 counted, uint32 matched) = preview(voice, toPollId);
        next[voice] = to;

        Link memory l = links[voice];
        bytes32 hash = keccak256(abi.encode(block.chainid, address(POLLS), voice, from, to, counted, matched));
        emit Attested(voice, l.agentId, from, to, counted, matched, hash);
        if (counted == 0) return;

        if (l.owner == address(0)) revert NotLinked();
        if (IDENTITY.ownerOf(l.agentId) != l.owner) revert OwnerChanged();
        REPUTATION.giveFeedback(
            l.agentId,
            int128(uint128(uint256(matched) * 100 / counted)),
            0,
            TAG_ACCURACY,
            TAG_SOURCE,
            ENDPOINT,
            "",
            hash
        );
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
