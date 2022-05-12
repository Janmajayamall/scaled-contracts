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

    uint256 reserves;

    uint256 constant ECDSA_SIGNATURE_LENGTH = 65;

    constructor(address _token) {
        token = _token;
    }

    function getBalance(address user) internal view returns(uint256) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, user));
        if (!success || data.length != 32){
            // revert with balance error
            revert();
        }
        return abi.decode(data, (uint256));
    }

    function receiptIdentifier(Receipt calldata receipt)
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

    function receiptHash(Receipt calldata receipt)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encodePacked(
                    receipt.aAddress,
                    receipt.bAddress,
                    receipt.seqNo,
                    receipt.amount,
                    receipt.expiresBy
                )
            );
    }

    function ecdsaRecover(bytes32 msgHash, bytes calldata signature) internal pure returns (address signer) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        if (signature.length != ECDSA_SIGNATURE_LENGTH) {
            // Malformed ecdsa signature
            revert();
        }

        assembly {
            // r = encodedSignature[0:32]
            r := calldataload(signature.offset)
            // s = encodedSignature[32:64]
            s := calldataload(add(signature.offset, 32))
            // v = uint8(encodedSignature[64:64])
            v := shr(248, calldataload(add(signature.offset, 64)))
        }

        signer = ecrecover(msgHash, v, r, s);

        if (signer == address(0)) {
            // Invalid ecdsa signature
            revert();
        }
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

    function post(Update[] calldata updates) public {
        for (uint256 i = 0; i < updates.length; i++) {
            // validate signatures
            bytes32 rHash = receiptHash(updates[i].receipt);
            if (
                updates[i].receipt.aAddress != ecdsaRecover(rHash, updates[i].aSignature) ||
                updates[i].receipt.bAddress != ecdsaRecover(rHash, updates[i].bSignature)  
            ) {
                // Invalid signature
                revert();
            }

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
            // FIXME we're recalculating `receipt` hash here
            record.lastRIdentifier = receiptIdentifier(updates[i].receipt);
            record.seqNo = updates[i].receipt.seqNo;
            record.fixedAfter = uint32(block.timestamp) + bufferPeriod;
            records[rKey] = record;
        }
    }

    function correctUpdate(Receipt calldata wR, Update calldata cUpdate) public {
        // validate `cUpdate` signatures
        bytes32 rHash = receiptHash(cUpdate.receipt);
        if (
            cUpdate.receipt.aAddress != ecdsaRecover(rHash, cUpdate.aSignature) ||
            cUpdate.receipt.bAddress != ecdsaRecover(rHash, cUpdate.bSignature)  
        ) {
            // Invalid signature
            revert();
        }

        Receipt calldata cR = cUpdate.receipt;

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
// 1. Once users move from `seq_no` to `seq_no + 1` ~ we assume that both users aggre that last `seq_no` receipt was settled properly.
// 2. We have a buffer period after account states have been updated (rn it is set to 7 days), before which affected accounts cannot
//    `withdraw`. This is done so to allow for anyone to correct the update using `correctUpdate` (if we omit buffer period, then dishonest
//    user will post "not latest receipt" in updates and immediately withdraw their money, so that honest user would not have any chance of correcting
//    the update)
// 3. When acceipting a receipt `b` should make sure that `a` has enough balance & security deposit relative to the `amount`.
// 4. We penalise users only on their security deposit, not from their account balance. This is done because security deposits are indicative 
//    of how likely a user is to cheat and should be used as an heuritic when accepting payments (i.e. low security deposit relative to amount should
//    be rejected).

// Still thinking
// 1. Should penalisation be proportional to `receipt.amount` or constant?