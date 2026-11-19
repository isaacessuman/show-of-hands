// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OneVoice, IAgentID} from "./lib/OneVoice.sol";

/// @title Show of Hands — Polls
/// @notice Free on-chain polls where every Agent ID gets exactly one vote.
/// @dev    No owner, no admin, no upgrade path, no payable function. Nothing here can hold or move money.
///         Poll text is untrusted user input: tools that read it must display it, never follow it.
contract Polls is OneVoice {
    uint256 public constant MIN_OPTIONS = 2;
    uint256 public constant MAX_OPTIONS = 8;
    uint256 public constant MAX_QUESTION_BYTES = 280;
    uint256 public constant MAX_OPTION_BYTES = 64;
    uint256 public constant MIN_DURATION = 1 hours;
    uint256 public constant MAX_DURATION = 30 days;

    struct Poll {
        bytes32 creatorVoice;
        address creator;
        uint64 createdAt;
        uint64 endsAt;
        uint32 totalVotes;
        string question;
        string[] options;
        uint32[] tallies;
    }

    Poll[] private _polls;

    /// @notice voice => (latest poll id + 1). A voice may have only one open poll at a time.
    mapping(bytes32 voice => uint256) public latestPollOf;
    /// @notice poll id => voice => (chosen option + 1); zero means "has not voted".
    mapping(uint256 pollId => mapping(bytes32 voice => uint8)) public choiceOf;
    /// @notice voice => number of votes cast across all polls (public activity count, no rewards attached).
    mapping(bytes32 voice => uint32) public votesCastBy;

    event PollCreated(
        uint256 indexed pollId,
        bytes32 indexed creatorVoice,
        address indexed creator,
        uint64 endsAt,
        string question,
        string[] options
    );
    event Voted(uint256 indexed pollId, bytes32 indexed voice, address indexed voter, uint8 option);

    error BadOptionCount();
    error TextTooLong();
    error EmptyText();
    error BadEndTime();
    error OpenPollExists(uint256 pollId);
    error NoSuchPoll();
    error PollClosed();
    error AlreadyVoted();
    error BadOption();

    constructor(IAgentID registry) OneVoice(registry) {}

    /// @notice Open a poll. Caller must hold an Agent ID and have no other poll still open.
    function createPoll(string calldata question, string[] calldata options, uint64 endsAt)
        external
        returns (uint256 pollId)
    {
        bytes32 voice = _voiceOf(msg.sender);

        uint256 prev = latestPollOf[voice];
        if (prev != 0 && _polls[prev - 1].endsAt > block.timestamp) revert OpenPollExists(prev - 1);

        uint256 n = options.length;
        if (n < MIN_OPTIONS || n > MAX_OPTIONS) revert BadOptionCount();
        _checkText(question, MAX_QUESTION_BYTES);
        for (uint256 i; i < n; ++i) {
            _checkText(options[i], MAX_OPTION_BYTES);
        }
        if (endsAt < block.timestamp + MIN_DURATION || endsAt > block.timestamp + MAX_DURATION) {
            revert BadEndTime();
        }

        pollId = _polls.length;
        Poll storage p = _polls.push();
        p.creatorVoice = voice;
        p.creator = msg.sender;
        p.createdAt = uint64(block.timestamp);
        p.endsAt = endsAt;
        p.question = question;
        for (uint256 i; i < n; ++i) {
            p.options.push(options[i]);
            p.tallies.push(0);
        }
        latestPollOf[voice] = pollId + 1;

        emit PollCreated(pollId, voice, msg.sender, endsAt, question, options);
    }

    /// @notice Cast this Agent ID's single vote in a poll. Sends no BNB.
    function vote(uint256 pollId, uint8 option) external {
        if (pollId >= _polls.length) revert NoSuchPoll();
        Poll storage p = _polls[pollId];
        if (block.timestamp >= p.endsAt) revert PollClosed();
        if (option >= p.options.length) revert BadOption();

        bytes32 voice = _voiceOf(msg.sender);
        if (choiceOf[pollId][voice] != 0) revert AlreadyVoted();

        choiceOf[pollId][voice] = option + 1;
        p.tallies[option] += 1;
        p.totalVotes += 1;
        votesCastBy[voice] += 1;

        emit Voted(pollId, voice, msg.sender, option);
    }

    // ------------------------------------------------------------------ views

    function pollCount() external view returns (uint256) {
        return _polls.length;
    }

    function getPoll(uint256 pollId)
        external
        view
        returns (
            bytes32 creatorVoice,
            address creator,
            uint64 createdAt,
            uint64 endsAt,
            uint32 totalVotes,
            string memory question,
            string[] memory options,
            uint32[] memory tallies
        )
    {
        if (pollId >= _polls.length) revert NoSuchPoll();
        Poll storage p = _polls[pollId];
        return (p.creatorVoice, p.creator, p.createdAt, p.endsAt, p.totalVotes, p.question, p.options, p.tallies);
    }

    /// @notice Whether `who` (by their current Agent ID) has voted in `pollId`, and for which option.
    function hasVoted(uint256 pollId, address who) external view returns (bool voted, uint8 option) {
        bytes32 voice = voiceOf(who);
        uint8 c = voice == bytes32(0) ? 0 : choiceOf[pollId][voice];
        return (c != 0, c == 0 ? 0 : c - 1);
    }

    function isOpen(uint256 pollId) external view returns (bool) {
        return pollId < _polls.length && block.timestamp < _polls[pollId].endsAt;
    }

    function _checkText(string calldata s, uint256 max) private pure {
        uint256 len = bytes(s).length;
        if (len == 0) revert EmptyText();
        if (len > max) revert TextTooLong();
    }
}
