// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BLS} from "./libraries/BLS.sol";

contract StateBLS {

    struct Account {
        uint128 balance;
        uint32 withdrawAfter;
    }

    struct Record {
        uint128 amount;
        uint16 seqNo;
        uint32 fixedAfter;
        bool slashed;
        uint32 expiresBy;
    }

    // Mappings needed
    // index to address
    // index to blsPk (128 bytes)
    mapping (uint64 => address) addresses;
    mapping (uint64 => uint256[4]) blsPublicKeys;
    mapping (uint64 => Account) accounts;
    mapping (bytes32 => Record) records;

    mapping (uint64 => uint256) securityDeposits;

    uint64 public userCount;

    bytes32 constant blsDomain = keccak256("Test");

    uint32 constant bufferPeriod = uint32(7 days);

    // duration is a week in seconds
    uint32 constant duration = 604800;


    function currentCycleExpiry() public view returns (uint32) {
        // `expiredBy` value of a `receipt = roundUp(block.timestamp / duration) * duration`
        return uint32(((block.timestamp / duration) + 1) * duration);
    }

    function recordKey(uint64 a, uint64 b) internal returns (bytes32) {
        return keccak256(abi.encode(a, "++", b));
    }

    function getUpdateAtIndex(uint256 i) internal view returns (
        // 8 bytes
        uint64 bIndex,
        // 16 bytes
        uint128 amount
    ){
        uint256 offset = 14 + (i * 24);
        assembly {
            bIndex := shr(192, calldataload(offset))

            offset := add(offset, 8)
            amount := shr(128, calldataload(offset))
        }

        // console.log("---------------");
        // console.log("Gen Update");
        // console.log("bIndex", r.bIndex);
        // console.log("amount", amount);
        // console.logBytes(r.aSignature);
        // console.logBytes(r.bSignature);
        // console.log("---------------");
    }

    function register(
        address userAddress,
        uint256[4] calldata pk
    ) external {
        uint64 userIndex = userCount + 1;
        userCount = userIndex;

        // get y of blsPk
        addresses[userIndex] = userAddress;
        blsPublicKeys[userIndex] = pk;

        // emit event
    }

    function msgHashBLS(
        uint64 aIndex,
        uint64 bIndex,
        uint128 amount,
        uint64 expiresBy,
        uint16 seqNo
    ) internal returns (uint256[2] memory) {
        bytes memory message = abi.encodePacked(aIndex, bIndex, amount, expiresBy, seqNo);
        return BLS.hashToPoint(blsDomain, message);
    }

    function post() external {
        uint64 aIndex;
        uint16 count;
        uint256[2] memory signature;

        assembly {
            aIndex := shr(192, calldataload(4))
            count := shr(240, calldataload(12))

            // signature
            mstore(add(signature, 32), calldataload(14))
            mstore(add(signature, 64), calldataload(46))
        }

        uint256[4] memory aPublicKey = blsPublicKeys[aIndex];
        Account memory aAccount = accounts[aIndex];
        
        uint256[4][] memory publicKeys = new uint256[4][](count * 2);
        uint256[2][] memory messages = new uint256[2][](count * 2);

        uint32 expiresBy = currentCycleExpiry();

        for (uint256 i = 0; i < count; i++) {
            (uint64 bIndex, uint128 amount) = getUpdateAtIndex(i);

            bytes32 rKey = recordKey(aIndex, bIndex);
            Record memory record = records[rKey];
            record.amount = amount;
            record.expiresBy = expiresBy;
            record.fixedAfter = uint32(block.timestamp + bufferPeriod);
            record.seqNo += 1;

            uint256[4] memory bPublicKey = blsPublicKeys[bIndex];
            uint256[2] memory hash = msgHashBLS(aIndex, bIndex, amount, expiresBy, record.seqNo);
            messages[i] = hash;
            messages[count+i] = hash;
            publicKeys[i] = bPublicKey;
            publicKeys[count+i] = aPublicKey;

            Account memory bAccount = accounts[bIndex];
            if (bAccount.balance < amount){
                amount = bAccount.balance;
                bAccount.balance = 0;
                // slash `b`
                securityDeposits[bIndex] = 0;
            }else {
                bAccount.balance -= amount;
            }
            aAccount.balance += amount;

            // `b` can only withdraw after buffer period, so that ample time is provided
            // for challange update.
            // Note we don't need buffer period for `a` since "challenge update" can only
            // increase their balance, not decrease.
            bAccount.withdrawAfter = uint32(block.timestamp + bufferPeriod);
            accounts[bIndex] = bAccount;
        }

        accounts[aIndex] = aAccount;

        // verify signatures
        (bool result, bool success) = BLS.verifyMultiple(signature, publicKeys, messages);
        if (!result || !success){
            revert();
        }

        // emit update event
    }

}

// fullReceipt {
//     aIndex
//     bIndex
//     amount
//     expiresBy
//     seqNo.
// }