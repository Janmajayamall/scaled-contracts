// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "./interfaces/IERC20.sol";
import "./libraries/Transfers.sol";
import "./../test/Console.sol";

/// Optimizes heavily to reduce calldata.
/// Old implementation without BLS
contract StateL2 {
    
    struct PartialReceipt {
        uint64 bIndex;
        uint128 amount;
        bytes aSignature;
        bytes bSignature;
    }

    struct Account {
        // Current account balance
        uint128 balance;
        // This is the latest of all update time 
        uint32 withdrawAfter;
    }

    struct Record {
        // Latest update amount
        uint128 amount;
        // Latest sequence no.
        uint16 seqNo;
        // Time after which update corresponding to this record will finalise
        uint32 fixedAfter;
        // Flag of whether `b` was slashed for overspending
        bool slashed;
    }

    mapping(uint64 => address) public addresses;
    mapping(address => uint64) public usersIndex;

    mapping(uint64 => Account) public accounts;
    mapping(bytes32 => Record) public records;
    // mapping(index => uint256) public slashAmounts;
    mapping(uint64 => uint256) public securityDeposits;

    // slashing amount = 1 Unit
    uint256 constant slashValue = 1e18;
    uint32 constant bufferPeriod = uint32(7 days);
    address immutable token;

    uint64 public userCount;
    uint256 reserves;

    uint256 constant ECDSA_SIGNATURE_LENGTH = 65;

    // duration is a week in seconds
    uint32 constant duration = 604800;

    constructor(address _token) {
        token = _token;
    }

    function currentCycleExpiry() public view returns (uint32) {
        // `expiredBy` value of a `receipt = roundUp(block.timestamp / duration) * duration`
        return uint32(((block.timestamp / duration) + 1) * duration);
    }

    function recordKey(uint64 a, uint64 b)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(a, "++", b));
    }

    function getAccount(uint64 ofIndex) public view returns (Account memory a){
        a = accounts[ofIndex];
    }

    function register(address user) external {
        uint64 c = userCount + 1;
        userCount = c;

        addresses[c] = user;
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

        Account memory account = accounts[toIndex];
        account.balance += uint128(amount);
        accounts[toIndex] = account;
    }


    // TODO add signature verification here
    function withdraw(uint64 fromIndex, uint128 amount,bytes memory signature) external {
        Account memory account = accounts[fromIndex];

        // check whether user's account isn't in
        // buffer period
        if (account.withdrawAfter >= block.timestamp) {
            revert();
        }

        account.balance -= amount;
        accounts[fromIndex] = account;

        Transfers.safeTransfer(IERC20(token), addresses[fromIndex], amount);
        reserves -= amount;

        // emit event
    }

    function getTokenBalance(address user) internal view returns(uint256) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, user));
        if (!success || data.length != 32){
            // revert with balance error
            revert();
        }
        return abi.decode(data, (uint256));
    }

    function getUpdateAtIndex(uint256 i) internal view returns (PartialReceipt memory r){
        // 8 bytes
        uint64 bIndex;
        // 16 bytes
        uint128 amount;
        // 65 bytes
        bytes memory aSignature = new bytes(65);
        // 65 bytes
        bytes memory bSignature = new bytes(65);

        uint256 offset = 14 + (i * 154);
        assembly {
            bIndex := shr(192, calldataload(offset))

            offset := add(offset, 8)
            amount := shr(128, calldataload(offset))

            // aSignature
            offset := add(offset, 16)
            mstore(add(aSignature,32), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(aSignature,64), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(aSignature,96), calldataload(offset))

            // bSignature
            offset := add(offset, 1)
            mstore(add(bSignature,32), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(bSignature,64), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(bSignature,96), calldataload(offset))
        }

        r = PartialReceipt({
            bIndex: bIndex,
            amount: amount,
            aSignature: aSignature,
            bSignature: bSignature
        });

        // console.log("---------------");
        // console.log("Gen Update");
        // console.log("bIndex", r.bIndex);
        // console.log("amount", amount);
        // console.logBytes(r.aSignature);
        // console.logBytes(r.bSignature);
        // console.log("---------------");
    }

    function receiptHash(
        uint64 aIndex,
        uint64 bIndex,
        uint128 amount,
        uint32 expiresBy,
        uint16 seqNo
    ) internal view returns (bytes32){
        return keccak256(
            abi.encodePacked(
                aIndex,
                bIndex,
                amount,
                expiresBy,
                seqNo
            )
        );
    }

    function ecdsaRecover(bytes32 msgHash, bytes memory signature) internal view returns (address signer) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        if (signature.length != ECDSA_SIGNATURE_LENGTH) {
            // Malformed ecdsa signature
            revert();
        }

        assembly {
            let offset := add(signature,32)
            // r = encodedSignature[0:32]
            r := mload(offset)
            // s = encodedSignature[32:64]
            offset := add(offset, 32)
            s := mload(offset)
            // v = uint8(encodedSignature[64:64])
            offset := add(offset, 32)
            v := shr(248, mload(offset))
        }


        signer = ecrecover(msgHash, v, r, s);
        if (signer == address(0)) {
            // Invalid ecdsa signature
            revert();
        }
    }
    
    // calldata format:
    // {
    //     bytes4(keccack256(post()))
    //     aIndex (8 bytes)
    //     count (2 bytes)
    //     updates[]: each {
    //         bIndex (8 bytes)
    //         amount (16 bytes)
    //         aSignature (65 bytes)
    //         bSignature (65 bytes)
    //     }
    // }
    function post() external {
        uint64 aIndex;
        uint16 count;

        assembly {
            aIndex := shr(192, calldataload(4))
            count := shr(240, calldataload(add(4, 8)))
        }

        address aAddress = addresses[aIndex];
        Account memory aAccount = accounts[aIndex];

        uint32 expiresBy = currentCycleExpiry();

        for (uint256 i = 0; i < count; i++) {
            PartialReceipt memory pR = getUpdateAtIndex(i);

            address bAddress = addresses[pR.bIndex];

            bytes32 rKey = recordKey(
                aIndex,
                pR.bIndex
            );   
            Record memory record = records[rKey];

            // update record
            record.seqNo += 1;
            record.amount = pR.amount;
            record.fixedAfter = uint32(block.timestamp) + bufferPeriod;

            // validate signatures
            bytes32 rHash = receiptHash(aIndex, pR.bIndex, pR.amount, expiresBy, record.seqNo);
            if (
                ecdsaRecover(rHash, pR.aSignature) != aAddress ||
                ecdsaRecover(rHash, pR.bSignature) != bAddress
            ) {
                revert();
            }

            // update account objects
            Account memory bAccount = accounts[pR.bIndex];
            if (bAccount.balance < pR.amount){
                // slashing `b`
                securityDeposits[pR.bIndex] = 0;
                record.slashed = true;

                pR.amount = bAccount.balance;
                bAccount.balance = 0;
            }else {
                bAccount.balance -= pR.amount;
                record.slashed = false;
            }
            aAccount.balance += pR.amount;
            bAccount.withdrawAfter = uint32(block.timestamp) + bufferPeriod;
            
            accounts[pR.bIndex] = bAccount;

            // store updated record    
            records[rKey] = record;
        }   

        accounts[aIndex] = aAccount;
        // emit event     
    }

    function correctUpdate() external {
        uint64 aIndex;
        uint64 bIndex;
        uint128 newAmount;
        uint32 expiresBy;
        bytes memory aSignature = new bytes(65);
        bytes memory bSignature = new bytes(65);

        assembly {
            let offset := 4
            aIndex := shr(192, calldataload(offset))
            offset := add(offset, 8)
            bIndex := shr(192, calldataload(offset))
            offset := add(offset, 8)
            newAmount := shr(128, calldataload(offset))
            offset := add(offset, 16)
            expiresBy := shr(224, calldataload(offset))
            offset := add(offset, 4)
            
            // aSignature
            mstore(add(aSignature,32), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(aSignature,64), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(aSignature,96), calldataload(offset))
            offset := add(offset, 1)

            // bSignature
            mstore(add(bSignature,32), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(bSignature,64), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(bSignature,96), calldataload(offset))
        }

        bytes32 rKey = recordKey(aIndex, bIndex);
        Record memory record = records[rKey];

        // validate signatures & receipt
        bytes32 rHash = receiptHash(aIndex, bIndex, newAmount, expiresBy, record.seqNo);

        if (
            ecdsaRecover(rHash, aSignature) != addresses[aIndex] ||
            ecdsaRecover(rHash, bSignature) != addresses[bIndex] ||
            // amount of latest `receipt` is always greater
            record.amount >= newAmount || 
            // `expiresBy` should be a multiple `duration`
            expiresBy % duration != 0 ||
            // cannot correct update after `fixedPeriod`
            record.fixedAfter <= block.timestamp
        ){
            revert();
        }

        // update account objects
        uint128 amountDiff = newAmount - record.amount;
        record.amount = newAmount;
        Account memory bAccount = accounts[bIndex];
        if (bAccount.balance < amountDiff) {
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

        Account memory aAccount = accounts[aIndex];
        aAccount.balance += amountDiff;
        accounts[aIndex] = aAccount;

        bAccount.withdrawAfter = uint32(block.timestamp) + bufferPeriod;
        accounts[bIndex] = bAccount;

        record.fixedAfter = uint32(block.timestamp) + bufferPeriod;
        records[rKey] = record;
    }
}