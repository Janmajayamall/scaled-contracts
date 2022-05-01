// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

library Smt {
    bytes32 constant placeholderHash = keccak256("");
    uint256 constant proofLength = 256;

    // check proof
    function verifyCompactProof(
        bytes32 bitmask,
        bytes32[] memory nodes,
        bytes32 expectedRoot,
        bytes32 currHash,
        bytes32 path
    ) internal pure returns (bool) {
        uint256 position;
        for (uint256 index = 0; index < proofLength; index++) {
            bytes32 currData;
            if (msBit(bitmask, index + 1) == 1) {
                // use placeholder
                currData = placeholderHash;
            } else {
                // use value from array
                currData = nodes[position];
                position += 1;
            }

            if (msBit(path, 256 - index) == 1) {
                currHash = keccak256(abi.encodePacked(currData, currHash));
            } else {
                currHash = keccak256(abi.encodePacked(currHash, currData));
            }
        }

        return currHash == expectedRoot;
    }

    function updatedRoot(
        bytes32 bitmask,
        bytes32[] memory nodes,
        bytes32 currHash,
        bytes32 path
    ) internal pure returns (bytes32) {
        uint256 position;
        for (uint256 index = 0; index < proofLength; index++) {
            bytes32 currData;
            if (msBit(bitmask, index + 1) == 1) {
                // use placeholder
                currData = placeholderHash;
            } else {
                // use value from array
                currData = nodes[position];
                position += 1;
            }

            if (msBit(path, 256 - index) == 1) {
                currHash = keccak256(abi.encodePacked(currData, currHash));
            } else {
                currHash = keccak256(abi.encodePacked(currHash, currData));
            }
        }

        return currHash;
    }

    function msBit(bytes32 value, uint256 bit) internal pure returns (uint8) {
        assert(bit > 0 && bit <= 256);
        return uint8((uint256(value) >> (256 - bit)) << (bit - 1));
    }
}
