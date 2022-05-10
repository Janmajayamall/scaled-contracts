// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

contract State {
    /**
        * Receipt = { 
            a_address,
            b_address,
            a_owes,
            b_owes,
        }
        And a&b both need to sign this

        * Don't want to store the addres, thus take hash(of address) as account location
        AccountObj { 
            balance: 128
            withdraw_after: 32
        }

        * Store latest seq no. between A & B at H(A,B) location
            - Only accept receipts with greater seq no.

        * 
            - A posts W receipt on chain
            - A withdraws money

            Buffer period
            - "A" posts "W" receipt on chain 
            - "B" posts "C" receipt on chain ~ this reverses the state and updates it correctly

            on every account update -> extend withdrawam time to timestamp + 7 days??
    */

    struct Account {
        uint128 balance;
        uint32 withdrawAfter;
    }

    struct Receipt {
        address aAddress;
        address bAddress;
        uint128 aOwes;
        uint128 bOwes;
        uint16 seqNo;
        uint32 expiresBy;
    }

    struct Update {
        Receipt receipt;
        bytes aSignature;
        bytes bSignature;
    }

    struct Record {
        // Storing only first 160 bits of last receipt hash
        uint160 lastRHash;
        uint16 seqNo;
        uint32 fixedAfter;
    }

    mapping(address => Account) accounts;
    // H(A,B)
    mapping(bytes32 => Record) records;

    function receiptIdentifier(Receipt memory receipt)
        internal
        pure
        returns (uint160)
    {
        return
            uint160(uint256(keccak256(
                abi.encodePacked(
                    receipt.aAddress,
                    receipt.bAddress,
                    receipt.aOwes,
                    receipt.bOwes
                )
            )));
    }

    function recordHash(address aAddress, address bAddress)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(aAddress, bAddress));
    }

    function relay(Update[] memory updates) public {
        for (uint256 i = 0; i < updates.length; i++) {
            // validate signatures

            // validate receipt
            bytes32 recordKey = recordHash(
                updates[i].receipt.aAddress,
                updates[i].receipt.bAddress
            );
            Record memory record = records[
                recordHash(
                    updates[i].receipt.aAddress,
                    updates[i].receipt.bAddress
                )
            ];
            if (
                record.seqNo + uint16(1) != updates[i].receipt.seqNo ||
                updates[i].receipt.expiresBy <= block.timestamp
            ) {
                revert();
            }

            // receipt is valid

            // update record
            record.lastRHash = receiptIdentifier(updates[i].receipt);
            record.seqNo = updates[i].receipt.seqNo;
            record.fixedAfter = uint32(block.timestamp + 7 days);
            records[recordKey] = record;

            // update account objects
            updateAccount(updates[i].receipt.aAddress, updates[i].receipt.bOwes, updates[i].receipt.aOwes);
            updateAccount(updates[i].receipt.bAddress, updates[i].receipt.aOwes, updates[i].receipt.bOwes);
        }
    }

    function updateAccount(address uAddress, uint128 owed, uint128 owes) internal {
        Account memory account = accounts[uAddress];
        account.balance += owed;
        if (account.balance < owes){
            // TODO decrease 
            account.balance = 0;
        }else {
            account.balance -= owes;
        }
        // buffer period = 7 days
        account.withdrawAfter = uint32(block.timestamp + 7 days);
        accounts[uAddress] = account;
    }


    function correctUpdate(Receipt calldata wR, Receipt calldata cR) public {
        bytes32 recordKey = recordHash(
            wR.aAddress,
            cR.bAddress
        );

        // rHash should match H(wR)
        Record memory record = records[recordKey];
        if (record.fixedAfter <= block.timestamp) {
            // You can change after buffer period
            revert();
        }

        // addresses in `wR` & `cR` should match
        if (wR.aAddress != cR.aAddress || wR.bAddress != cR.bAddress) {
            revert();
        }

        // cR should have expiresBy greater than in wR
        if (cR.expiresBy <= wR.expiresBy) {
            revert();
        }

        // apply the updates
        // we reverse owed & owes to revert the effec or `wR`
        updateAccount(wR.aAddress, wR.aOwes, wR.bOwes);
        updateAccount(wR.bAddress, wR.bOwes, wR.aOwes);

        // apply cR
        updateAccount(wR.aAddress, wR.bOwes, wR.aOwes);
        updateAccount(wR.bAddress, wR.aOwes, wR.bOwes);
    }
}

// Things to keep in mind
// 1. Once users move from `seq_no` to `seq_no + 1` ~ we assume that both users aggree that last `seq_no` receipt was settled properly.
// 2. I don't think we should  *not allow*  users from calling `correctUpdate` after expiry - because dishonest user `A` can cheat
//    by posting old receipt (but valid) right before timestamp expiry (we are assuming that receipts can change eveen after 1 sec).
// 3. What we can do is this - You can call `correctUpdate` anytime within `bufferPeriod`.
// 4. Security deposit should be something significant. Plus, receipts with `a(b)Owes` >= 10% of a(b)SecurityDeposit should be considered
//    risky.
// 5. How about slashing user on deposit/withdrawal if their balance if negative
