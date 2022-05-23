// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BLS} from "./libraries/BLS.sol";
import "./interfaces/IERC20.sol";
import "./libraries/Transfers.sol";
import "hardhat/console.sol";

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
    }

    mapping (uint64 => address) addresses;
    mapping (uint64 => uint256[4]) blsPublicKeys;
    mapping (uint64 => Account) accounts;
    mapping (bytes32 => Record) records;
    mapping (uint64 => uint256) securityDeposits;

    uint64 public userCount = 4294967296;
    address immutable token;
    uint256 reserves;

    bytes32 constant blsDomain = keccak256(abi.encodePacked("test"));
    uint32 constant bufferPeriod = uint32(7 days);
    // duration is a week in seconds
    uint32 constant duration = 604800;

    constructor(address _token) {
        token = _token;
    }

    function currentCycleExpiry() public view returns (uint32) {
        // `expiredBy` value of a `receipt = roundUp(block.timestamp / duration) * duration`
        return uint32(((block.timestamp / duration) + 1) * duration);
    }

    function recordKey(uint64 a, uint64 b) internal returns (bytes32) {
        return keccak256(abi.encode(a, "++", b));
    }

    function getTokenBalance(address user) internal view returns(uint256) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, user));
        if (!success || data.length != 32){
            // revert with balance error
            revert();
        }
        return abi.decode(data, (uint256));
    }

    function getUpdateAtIndex(uint256 i) internal view returns (
        // 8 bytes
        uint64 bIndex,
        // 16 bytes
        uint128 amount
    ){
        uint256 offset = 78 + (i * 24);
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
        console.log("Registerd user: ", userAddress, " at index:", userIndex);
    }


    function msgHashBLS(
        uint64 aIndex,
        uint64 bIndex,
        uint128 amount,
        uint32 expiresBy,
        uint16 seqNo
    ) internal returns (uint256[2] memory) {
        bytes memory message = abi.encodePacked(aIndex, bIndex, amount, expiresBy, seqNo);
        return BLS.hashToPoint(blsDomain, message);
    }

    function depositSecurity(uint64 toIndex) external {
         // get amount deposited
        uint256 balance = getTokenBalance(address(this));
        uint256 amount = balance - reserves;
        reserves = balance;

        securityDeposits[toIndex] += amount;
    }

    function fundAccount(uint64 toIndex) external {
        // get amount deposited
        uint256 balance = getTokenBalance(address(this));
        uint256 amount = balance - reserves;
        reserves = balance;

        console.log("Funding account of user with address: ", addresses[toIndex]);

        Account memory account = accounts[toIndex];
        account.balance += uint128(amount);
        accounts[toIndex] = account;
    }

    function post() external {
        uint64 aIndex;
        uint16 count;
        uint256[2] memory signature;

        assembly {
            aIndex := shr(192, calldataload(4))
            count := shr(240, calldataload(12))

            // signature
            mstore(add(signature, 0), calldataload(14))
            mstore(add(signature, 32), calldataload(46))
        }

        console.logBytes32(blsDomain);
        console.log("count:", count);
        console.log("aIndex:", aIndex);
        console.log("signature[0]", signature[0]);
        console.log("signature[1]", signature[1]);

        Account memory aAccount = accounts[aIndex];
        
        uint256[4][] memory publicKeys = new uint256[4][](count * 2);
        uint256[2][] memory messages = new uint256[2][](count * 2);

        uint32 expiresBy = currentCycleExpiry();
        console.log("currentCycleExpiry:" ,expiresBy);

        for (uint256 i = 0; i < count; i++) {
            (uint64 bIndex, uint128 amount) = getUpdateAtIndex(i);

            console.log("Update", i);
            console.log("bIndex", bIndex);
            console.log("amount", amount);

            bytes32 rKey = recordKey(aIndex, bIndex);
            Record memory record = records[rKey];
            record.amount = amount;
            record.fixedAfter = uint32(block.timestamp + bufferPeriod);
            record.seqNo += 1;

            // prepare msg & b's key for signature verification
            uint256[2] memory hash = msgHashBLS(aIndex, bIndex, amount, expiresBy, record.seqNo);
            console.log("Hash[0]", hash[0]);
            console.log("Hash[1]", hash[1]);
            messages[i] = hash;
            messages[count + i] = hash; // for `a`
            publicKeys[i] = blsPublicKeys[bIndex];
            
            // update account
            Account memory bAccount = accounts[bIndex];
            if (bAccount.balance < amount){
                amount = bAccount.balance;
                bAccount.balance = 0;
                // slash `b`
                securityDeposits[bIndex] = 0;
                record.slashed = true;
            }else {
                bAccount.balance -= amount;
                record.slashed = false;
            }
            aAccount.balance += amount;

            // `b` can only withdraw after buffer period, so that ample time is provided
            // for challange update.
            // Note we don't need buffer period for `a` since "challenge update" can only
            // increase their balance, not decrease.
            bAccount.withdrawAfter = uint32(block.timestamp + bufferPeriod);
            accounts[bIndex] = bAccount;

            records[rKey] = record;
        }

        accounts[aIndex] = aAccount;

        // fill in publicKeys for `a`
        uint256[4] memory aPublicKey = blsPublicKeys[aIndex];
        for (uint256 i = 0; i < count; i++) {
            publicKeys[count + i] = aPublicKey;
        }
        console.log("It's here1!");
        // verify signatures
        (bool result, bool success) = BLS.verifyMultiple(signature, publicKeys, messages);
        console.log(result, success, "It's here!");
        if (!result || !success){
            revert();
        }

        // emit update event
    }

    function correctUpdate() external {
        uint128 newAmount;
        uint32 expiresBy;
        uint256[2] memory signature;
        uint64 aIndex;
        uint64 bIndex;

        // TODO get the data from assembly

        bytes32 rKey = recordKey(aIndex, bIndex);
        Record memory record = records[rKey];

        if (
            record.amount >= newAmount ||
            record.fixedAfter <= block.timestamp ||
            expiresBy % duration != 0 
        ){
            revert();
        }


        // validate signature
        uint256[2] memory hash = msgHashBLS(aIndex, bIndex, newAmount, expiresBy, record.seqNo);
        // FIXME aggregate public keys into one
        uint256[4][] memory publicKeys = new uint256[4][](2);
        publicKeys[0] = blsPublicKeys[aIndex];
        publicKeys[1] = blsPublicKeys[bIndex];
        uint256[2][] memory messages = new uint256[2][](2);
        messages[0] = hash;
        messages[1] = hash;
        (bool result, bool success) = BLS.verifyMultiple(signature, publicKeys, messages);
        if (!result || !success){
            revert();
        }

        // update accounts
        uint128 amountDiff = newAmount - record.amount;
        record.amount = newAmount;
        Account memory bAccount = accounts[bIndex];
        if (bAccount.balance < amountDiff){
            // slash `b` only if they were not
            // slashed for `seqNo` before
            if (!record.slashed){
                record.slashed = true;
                securityDeposits[bIndex] = 0;
            }

            amountDiff = bAccount.balance;
            bAccount.balance = 0;
        }else {
            bAccount.balance -= amountDiff;
        }
        bAccount.withdrawAfter = uint32(block.timestamp) + bufferPeriod;
        accounts[bIndex] = bAccount;

        Account memory aAccount = accounts[aIndex];
        aAccount.balance += amountDiff;
        accounts[aIndex] = aAccount;

        // update record
        record.fixedAfter = uint32(block.timestamp + bufferPeriod);
        records[rKey] = record;
    }

}
