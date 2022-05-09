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
        uint160 lastRHash;
        uint16 seqNo;
        uint32 fixedAfter;
    }

    mapping(address => Account) accounts;
    // H(A,B)
    mapping(bytes32 => Record) history;

    function receiptHash(Receipt memory receipt)
        internal
        view
        returns (bytes32)
    {
        return
            keccak256(
                abi.encodePacked(
                    receipt.aAddress,
                    receipt.bAddress,
                    receipt.aOwes,
                    receipt.bOwes
                )
            );
    }

    function recordHash(address aAddress, address bAddress)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(aAddress, bAddress));
    }

    function relay(Update[] memory updates) public {
        for (uint256 i = 0; i < updates.length; i++) {
            bytes32 rHash = receiptHash(updates[i].receipt);

            // validate signatures

            // validate receipt
            bytes32 recordKey = recordHash(
                updates[i].receipt.aAddress,
                updates[i].receipt.bAddress
            );
            Record memory record = history[
                recordHash(
                    updates[i].receipt.aAddress,
                    updates[i].receipt.bAddress
                )
            ];
            if (
                record.seqNo + uint16(1) != updates[i].seqNo ||
                updates[i].expiresBy <= block.timestamp
            ) {
                revert();
            }

            // receipt is valid

            // update record
            record.lastRHash = rHash;
            record.seqNo = updates[i].seqNo;
            record.fixedAfter = block.timestamp + 7 days;
            history[recordKey] = record;

            // update account objects
            Account memory aAccount = accounts[updates[i].receipt.aAddress];
            Account memory bAccount = accounts[updates[i].receipt.bAddress];

            // TODO handle negative case
            aAccount.balance += updates[i].receipt.bOwes;
            if (aAccount.balance < updates[i].receipt.aOwes) {
                // Ahhh...tried to cheat :P
                // Probably slash
                aAccount.balance = 0;
            } else {
                aAccount.balance -= updates[i].receipt.aOwes;
            }
            bAccount.balance += updates[i].receipt.aOwes;
            if (bAccount.balance < updates[i].receipt.bOwes) {
                // Ahhh...tried to cheat :P
                // Probably slash
                bAccount.balance = 0;
            } else {
                bAccount.balance -= updates[i].receipt.bOwes;
            }
            // buffer period = 7 days
            aAccount.withdrawAfter = block.timestamp + 7 days;
            bAccount.withdrawAfter = block.timestamp + 7 days;

            accounts[updates[i].receipt.aAddress] = aAccount;
            accounts[updates[i].receipt.bAddress] = bAccount;
        }
    }

    function correctUpdate(Receipt calldata wR, Receipt calldata cR) public {
        bytes32 recordKey = recordHash(
            wR.receipt.aAddress,
            cR.receipt.bAddress
        );

        // rHash should match H(wR)
        Record memory record = history[recordKey];
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
    }
}

// Things to keep in mind
// 1. Once users move from `seq_no` to `seq_no + 1` ~ we assume that both users aggree that last `seq_no` receipt was settled properly.
// 2. I don't think we should  *not allow*  users from calling `correctUpdate` after expiry - because dishonest user `A` can cheat
//    by posting old receipt (but valid) right before timestamp expiry (we are assuming that receipts can change eveen after 1 sec).
// 3. What we can do is this - You can call `correctUpdate` anytime withing `bufferPeriod`.
// 4. Security deposit should be something significant. Plus, receipts with `a(b)Owes` >= 10% of a(b)SecurityDeposit should be considered
//    risky.
