// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Test double for the Agent ID registry, with switches to simulate faults.
contract MockAgentID {
    mapping(address => string) public handles;
    mapping(bytes32 => address) public owners;
    bool public broken; // every read reverts
    address public forgedOwner; // if set, ownerOfHandle lies

    function give(address who, string calldata handle) external {
        handles[who] = handle;
        owners[keccak256(bytes(handle))] = who;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function setForgedOwner(address a) external {
        forgedOwner = a;
    }

    function balanceOf(address who) external view returns (uint256) {
        require(!broken, "broken");
        return bytes(handles[who]).length == 0 ? 0 : 1;
    }

    function handleOf(address who) external view returns (string memory) {
        require(!broken, "broken");
        return handles[who];
    }

    function ownerOfHandle(string calldata handle) external view returns (address) {
        require(!broken, "broken");
        if (forgedOwner != address(0)) return forgedOwner;
        return owners[keccak256(bytes(handle))];
    }
}

/// @dev A wallet that refuses BNB, to prove one bad recipient cannot block others.
contract Refuser {
    receive() external payable {
        revert("no");
    }
}
