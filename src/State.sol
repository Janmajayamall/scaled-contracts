// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./interfaces/IERC20.sol";
import "./libraries/Transfers.sol";

contract State {
  
    struct Account {
        // Current account balance
        uint128 balance;
        // This is the latest of all update time 
        uint32 withdrawAfter;
    }

    /// Receipt only maintains state of how much `a` owes `b`
    /// Note that owed `amount` can only increase in subsequent
    /// receipt states, thus subsequent receipts with lesser `amount` are 
    /// invalid 
    struct Receipt {
        /// `a` is the payer
        address aAddress;
        /// `b` is receiver
        address bAddress;
        /// amount that `a` owes `b`
        uint128 amount;
        /// sequence no. of the receipt
        uint16 seqNo;
        /// receipt is valid till before 
        /// expiresBy timestamp
        uint32 expiresBy;
    }

    struct Update { 
        // Receipt shared by A & B
        Receipt receipt;
        // A's signature on `receipt`
        bytes aSignature;
        // B's signature on `receipt`
        bytes bSignature;
    }

    struct Record {
        // Storing first 160 bits of `receipt` hash
        uint160 lastRIdentifier;
        // Latest sequence no. on `receipt` between A & B
        uint16 seqNo;
        // Time after which update corresponding to this record will finalise
        uint32 fixedAfter;
        // Flag of whether `a` was slashed for overspending
        bool slashed;
    }

    mapping(address => Account) accounts;
    /// Stores latest update record between A & B.
    mapping(bytes32 => Record) records;
    /// Total penalisation incurred by users for overspending.
    mapping(address => uint256) slashAmounts;
    /// Security deposit by users
    mapping(address => uint256) securityDeposits;

    // slashing amount is just 1ETH right now
    uint256 constant slashValue = 1e18;
    uint32 constant bufferPeriod = uint32(7 days);
    address immutable token;

    constructor(address _token) {
        token = _token;
    }

    uint256 reserves;

    function getBalance(address user) internal view returns(uint256) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, user));
        if (!success || data.length != 32){
            // revert with balance error
            revert();
        }
        return abi.decode(data, (uint256));
    }

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
                    receipt.seqNo,
                    receipt.amount,
                    receipt.expiresBy
                )
            )));
    }

    function recordKey(address aAddress, address bAddress)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(aAddress, bAddress));
    }

    function depositSecurity(address to) external {   
        // get amount deposited
        uint256 balance = getBalance(address(this));
        uint256 amount = balance - reserves;
        reserves = balance;

        uint256 totalDeposit = securityDeposits[to] + amount;
        
        // slash from `totalDeposit` if any
        uint256 slash = slashAmounts[to];
        if (slash != 0) {
            if (slash > totalDeposit){
                totalDeposit = 0;
                slash -= totalDeposit;
            }else {
                totalDeposit -= slash;
                slash = 0;
            }
            slashAmounts[to] = slash;
        }
        securityDeposits[to] = totalDeposit;
    }

    function fundAccount(address to) external {
        // get amount deposited
        uint256 balance = getBalance(address(this));
        uint256 amount = balance - reserves;
        reserves = balance;

        // check whether we need to slash the user
        // Note that we don't slash from the account 
        // balance.
        uint256 slash = slashAmounts[to];
        if (slash != 0){
            uint256 securityDeposit = securityDeposits[to];
            if (slash > securityDeposit) {
                securityDeposit = 0;
                slash -= securityDeposit;
            }else {
                securityDeposit -= slash;
                slash = 0;
            }
            slashAmounts[to] = slash;
            securityDeposits[to] = securityDeposit;
        }
        
        Account memory account = accounts[to];
        account.balance += uint128(amount);
        accounts[to] = account;

        // emit event
    }

    function withdraw(address to, uint128 amount) external {
        Account memory account = accounts[to];

        // check whether user's account isn't in
        // buffer period
        if (account.withdrawAfter >= block.timestamp) {
            revert();
        }

        // check slashing
        uint256 slash = slashAmounts[to];
        if (slash != 0){
            uint256 securityDeposit = securityDeposits[to];
            if (slash > securityDeposit){
                securityDeposit = 0;
                slash -= securityDeposit;
            }else {
                slash = 0;
                securityDeposit -= slash;
            }
            securityDeposits[to] = securityDeposit;
            slashAmounts[to] = slash;
        }

        account.balance -= amount;
        accounts[to] = account;

        Transfers.safeTransfer(IERC20(token), to, amount);
        reserves -= amount;

        // emit event
    }

    function post(Update[] memory updates) public {
        for (uint256 i = 0; i < updates.length; i++) {
            // validate signatures

            // validate receipt
            bytes32 rKey = recordKey(
                    updates[i].receipt.aAddress,
                    updates[i].receipt.bAddress
                );
            Record memory record = records[
                rKey
            ];

            if (
                // update receipt should be next receipt 
                record.seqNo + uint16(1) != updates[i].receipt.seqNo ||
                updates[i].receipt.expiresBy <= block.timestamp
            ) {
                revert();
            }

            // receipt is valid

            // update account objects
            Account memory aAccount = accounts[updates[i].receipt.aAddress];
            uint128 amount = updates[i].receipt.amount;
            bool slashed;
            if (amount < aAccount.balance){
                // slashing of A
                amount = aAccount.balance;
                aAccount.balance = 0;
                slashed = true;
            }else {
                aAccount.balance -= amount;
            }
            Account memory bAccount = accounts[updates[i].receipt.bAddress];
            bAccount.balance += amount;
            
            accounts[updates[i].receipt.aAddress] = aAccount;
            accounts[updates[i].receipt.bAddress] = bAccount;

            // update record
            record.lastRIdentifier = receiptIdentifier(updates[i].receipt);
            record.seqNo = updates[i].receipt.seqNo;
            record.fixedAfter = uint32(block.timestamp) + bufferPeriod;
            records[rKey] = record;
        }
    }

    function correctUpdate(Receipt calldata wR, Receipt calldata cR) public {

        // latest update record
        bytes32 rKey = recordKey(
            wR.aAddress,
            wR.bAddress
        );
        Record memory record = records[rKey];
        if (
            // receiptIdentifier of `wR` should match `record.lastRIdentifier`
            record.lastRIdentifier != receiptIdentifier(wR) ||
            // You can't change after buffer period (also handles cases of when `record` does not pre-exists)
            record.fixedAfter <= block.timestamp ||
            // addresses in `wR` & `cR` should match
            wR.aAddress != cR.aAddress || 
            wR.bAddress != cR.bAddress ||
            // cR should have expiresBy greater than in wR
            cR.expiresBy <= wR.expiresBy ||
            // cR should have more amount than wR
            cR.amount <= wR.amount
        ) {
            revert();
        }

        // amount difference between correct and wrong receipts
        uint128 amountDiff = cR.amount - wR.amount;

        // update account objects
        Account memory aAccount = accounts[cR.aAddress];
        bool slashed;
        if (aAccount.balance < amountDiff){
            // slash A for overspending
            amountDiff = aAccount.balance;
            aAccount.balance = 0;
            slashed = true;
        }else {
            aAccount.balance -= amountDiff;
        }
        Account memory bAccount = accounts[cR.bAddress];
        bAccount.balance += amountDiff;

        aAccount.withdrawAfter = uint32(block.timestamp) + bufferPeriod;
        bAccount.withdrawAfter = uint32(block.timestamp) + bufferPeriod;
        accounts[cR.aAddress] = aAccount;
        accounts[cR.bAddress] = bAccount;

        // Check whether `a` should be slashed
        // Note that if `a` was slashed in last update
        // they should not be slashed again.
        if (!record.slashed && slashed) {
            slashAmounts[cR.aAddress] += slashValue;
        }

        // update record
        record.lastRIdentifier = receiptIdentifier(cR);
        record.seqNo = cR.seqNo;
        record.fixedAfter = uint32(block.timestamp) + bufferPeriod;
        record.slashed = slashed;
        records[rKey] = record;

        // emit event
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

// How do you make sure that all accounts are fully collatorialised
// How about rejecting receipts

// 1. Don't take payments that are more than the balance
// 2. If you submit an update you will only get upto +ve balance + security deposit back

// So the user should keep the following in mind
// 1. Never accept receipt that exceeds the balance
// 2. 

// Reasons for have strong opnion of transaction type (i.e. A is payer, B is receiver ~ not having bidirectional payment)
// 1. Supports applications that we imagine this will enable
// 2. Strengthens security and reduces complexity of state (correction) updates. For example - (1) If we have bidirectional payments
// in which owed amounts can increase/decrease in subsequent updates, then handling correction for invalid updates is hard since to correct
// you will have to subtract balances which can result in negative balances.  