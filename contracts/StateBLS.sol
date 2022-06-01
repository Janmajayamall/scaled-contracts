// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BLS} from "./libraries/BLS.sol";
import "./interfaces/IERC20.sol";
import "./libraries/Transfers.sol";
// import "hardhat/console.sol";


contract StateBLS {

    struct Account {
        uint128 balance;
        uint32 nonce;
    }

    struct Record {
        uint16 seqNo;
    }

    struct Withdrawal {
        uint128 amount;
        uint32 validAfter;
    }

    mapping (uint64 => address) public addresses;
    mapping (uint64 => uint256[4]) public blsPublicKeys;
    mapping (uint64 => Account) public accounts;
    mapping (bytes32 => Record) public records;
    mapping (uint64 => uint256) public securityDeposits;

    mapping (uint64 => Withdrawal) public pendingWithdrawals;

    uint64 public userCount;
    address public immutable token;
    uint256 reserves;

    bytes32 constant blsDomain = keccak256(abi.encodePacked("test"));
    uint32 public constant bufferPeriod = uint32(1 days);

    // duration is a week in seconds
    uint32 constant duration = 604800;

    constructor(address _token) {
        token = _token;
    }

    function currentCycleExpiry() public view returns (uint32) {
        // `expiredBy` value of a `receipt = roundUp(block.timestamp / duration) * duration`
        return uint32(((block.timestamp / duration) + 1) * duration);
    }

    function recordKey(uint64 a, uint64 b) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(a, "++", b));
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

    /// At `register` we need proof of possesion of bls public keys (i.e. `blsPk`)
    ///
    /// To understand why do we need it imagine the simplest possible scenario -
    /// On `register` `b` registered their blsPk as pk_b (i.e. sk_b * g2)
    /// and `a`, being dishonest, registered their blsPk as pk_a where pk_a = sk_a * g2 - pk_b.
    /// Now `a` calls  `post()` fn with a single `receipt` that it shares with `b`.
    /// To verify that both `a` and `b` have signed the `receipt` that `a` posted 
    /// we need the following parameters
    ///     sig_agg: Supplied by `a`
    ///     pk_b & pk_a: Stored on-chain
    /// To verify we check
    ///     e(sig_agg, g2) == e(H, pk_b) * e (H, pk_a), where H = hash(receipt) * g1
    /// Now, 
    ///      Since, e(H, pk_b) * e (H, pk_a) =  e(H, pk_b + pk_a) AND pk_a = sk_a * g2 - pk_b
    ///      => e(H, pk_b) * e (H, pk_a) = e(H, pk_b + sk_a * g2 - pk_b) = e(H, sk_a * g2)
    /// This means,
    ///      If `a` sets sig_agg = sk_a * H then following would hold true
    ///         e(sig_agg, g2) = e(sk_a * H, g2) = e(H, sk_a * g2) = e(H, pk_b) * e (H, pk_a)
    /// Thus, `receipt` is considered valid even when `b` didn't sign it. 
    /// 
    /// By forcing `a` to present a valid signature (proof of possesion) at register would avoid this, 
    /// since it would mean that `a` holds a valid `sk_a` corresponding to `pk_a`. 
    /// If they present pk_a and pk_a = sk_a1 * g2 - pk_b, there's no way for `a` to derive
    /// `sk_a` thus they would fail to produce valid signature if this is the case.
    function register(
        address userAddress,
        uint256[4] calldata blsPk,
        uint256[2] calldata sk
    ) external {
        uint64 userIndex = userCount + 1;
        userCount = userIndex;


        addresses[userIndex] = userAddress;
        blsPublicKeys[userIndex] = blsPk;

        // For proof of possesion user signs `userAddress`
        bytes memory message = abi.encodePacked(userAddress);
        uint256[2] memory hash = BLS.hashToPoint(blsDomain, message);

        // validate bls signature `sk`
        (bool valid, bool success) = BLS.verifySingle(sk, blsPk, hash);
        if (!valid || !success){
            revert();
        }
    }

    function depositSecurity(uint64 toIndex) external {
        //  get amount deposited
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

        // console.log("Funding account of user with address: ", addresses[toIndex], "with amount", amount);

        Account memory account = accounts[toIndex];
        account.balance += uint128(amount);
        accounts[toIndex] = account;
    }

    /// To initialise withdrawal process user with index `userIndex` and Account `account` signs the following
    /// message with their BLS pv key
    ///     abi.encodePacked(account.nonce + 1, amount)
    /// Note that a pending withdrawal can be overriden by calling `initWithdraw` with with latest `nonce` but
    /// with different amount
    function initWithdraw(uint64 userIndex, uint128 amount, uint256[2] calldata signature) external {
        // verify signature
        uint256[2] memory hash = BLS.hashToPoint(blsDomain, abi.encodePacked(accounts[userIndex].nonce + 1, amount));
        (bool valid, bool success) = BLS.verifySingle(signature, blsPublicKeys[userIndex], hash);
        if (!valid || !success){
            revert();
        }

        pendingWithdrawals[userIndex] = Withdrawal ({ 
            amount: amount,
            validAfter: uint32(block.timestamp) + bufferPeriod
        });
    }

    /// Finishes pending withdrawal and increases account nonce by 1
    function processWithdrawal(uint64 userIndex) external {
        Withdrawal memory withdrawal = pendingWithdrawals[userIndex];
        Account memory account = accounts[userIndex];

        if (
            withdrawal.validAfter >= block.timestamp ||
            account.balance < withdrawal.amount
        ){
            revert();
        }

        // transfer amount
        IERC20(token).transfer(addresses[userIndex], withdrawal.amount);
        
        // update account
        account.balance -= withdrawal.amount;
        account.nonce += 1;
        accounts[userIndex] = account;

        pendingWithdrawals[userIndex] = Withdrawal({
            validAfter:0,
            amount:0
        });
    }


    /// Called by `a` to post all receipts that they share with 
    /// others (other `b`s) on-chain and reflect receipts amounts in respective
    /// accounts.
    ///
    /// Each receipt causes two accounts updates that is of `a` & `b`.
    /// Since, a receipt represents how much `b` owes `a` it causes an 
    /// increase in `a`'s acc balance and decrease in `b`'s account 
    /// balance.
    ///
    /// Each receipt should have expiry set to `>= currentCycle`, otherwise 
    /// it is considered expired & not valid anymore.
    ///
    /// Each receipt should be a follow on the previous receipt with `seqNo - 1`.
    /// Note that it is `a`s and `b`s respobility to set their new receipt with
    /// `seqNo + 1` where seqNo. = sequence of receipt that was settled on chain.
    /// Once either of them sign a receipt with updated seqNo they confirm that 
    /// previous receipt was posted on-chain correctly.
    ///
    /// Aggregated BLS signature (i.e. signature) includes (a) signatures of `b`s 
    /// on their receipt that they share with `a` (b) a's signature on latest
    /// `commitmentData`. We do not check `a`'s signature on receipts, since they 
    /// sign hash of `commitmentData`
    /// commitmentData = {
    ///     bytes memory commitmentData
    ///     for r in receipts {
    ///               commitmentData = bytes.concat(commitmentData, r.bIndex, r.amount, r.seqNo)
    ///     }
    /// }
    /// 
    /// Calldata:
    ///     fnSelector (4 bytes)
    ///     aIndex(8 bytes) - a's Index
    ///     count (2 bytes) - No. of receipts 
    ///     signature (64 bytes) - BLS aggregated signature on all receipts
    ///     `each` receipt (24 bytes): {
    ///         bIndex (8 bytes)
    ///         amount (16 bytes)
    ///     }
    ///     
    /// Calldata encoding
    ///     <fnSelector + aIndex + count + signature + {bIndex + amount} for each receipt>       
    ///
    /// Note that we only need `bIndex` & `amount` to reconstruct a receipt because `aIndex`, 
    /// `expiresBy` & `seqNo` can reproduced.
    ///
    /// Moreover by aggregating (using BLS) all signatures on every receipt into one `signature` 
    /// and storing blsPubKeys of users in contract storage we avoid needing any other info for receipt
    /// validity verification.
    function post() external {
        // FIXME: Only for measuring executation gas
        // uint gasRef = gasleft();

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

        // console.logBytes32(blsDomain);
        // console.log("count:", count);
        // console.log("aIndex:", aIndex);
        // console.log("signature[0]", signature[0]);
        // console.log("signature[1]", signature[1]);

        Account memory aAccount = accounts[aIndex];
        
        uint256[4][] memory publicKeys = new uint256[4][]((count) + 1);
        uint256[2][] memory messages = new uint256[2][]((count) + 1);

        uint32 expiresBy = currentCycleExpiry();
        // console.log("currentCycleExpiry:" ,expiresBy);

        bytes memory commitmentData;

        for (uint256 i = 0; i < count; i++) {
            (uint64 bIndex, uint128 amount) = getUpdateAtIndex(i);

            // console.log("Update", i);
            // console.log("bIndex", bIndex);
            // console.log("amount", amount);

            // prepare msg hash & b's key for signature verification
            bytes32 rKey = recordKey(aIndex, bIndex);
            Record memory record = records[rKey];
            record.seqNo += 1;
            messages[i] = msgHashBLS(aIndex, bIndex, amount, expiresBy, record.seqNo);
            publicKeys[i] = blsPublicKeys[bIndex];
            commitmentData = bytes.concat(commitmentData, abi.encodePacked(bIndex, amount, record.seqNo));

            // update record
            records[rKey] = record;

            // console.log("Hash[0]", hash[0]);
            // console.log("Hash[1]", hash[1]);

            // console.log(publicKeys[i][0], publicKeys[i][1], "B's public key");
            
            // update account
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
            accounts[bIndex] = bAccount;
        }

        // update account
        accounts[aIndex] = aAccount;

        // add signature verification for `commitmentData`
        uint256[2] memory pHash = BLS.hashToPoint(blsDomain, commitmentData);
        messages[count + 1] = pHash;
        publicKeys[count + 1] = blsPublicKeys[aIndex];

        // verify signatures
        (bool result, bool success) = BLS.verifyMultiple(signature, publicKeys, messages);
        // console.log(result, success, "Er");
        if (!result || !success){
            revert();
        }

        // FIXME: Only for measuring executation gas
        // gasRef = gasRef - gasleft() ;   
        // console.log("Gas consumed:", gasRef);
    }

    /// With addition of `commitmentData` and differentiation between
    /// role of `a` and `b` `correctUpdate` is no more necessary
    ///
    // function correctUpdate() external {
    //     uint128 newAmount;
    //     uint32 expiresBy;
    //     uint256[2] memory signature;
    //     uint64 aIndex;
    //     uint64 bIndex;

    //     // TODO get the data from assembly
    //     assembly {
    //         newAmount := shr(128, calldataload(4))
    //         expiresBy := shr(224, calldataload(20))

    //         // signature
    //         mstore(signature, calldataload(24))
    //         mstore(add(signature, 32), calldataload(56))

    //         aIndex := shr(192, calldataload(88))
    //         bIndex := shr(192, calldataload(96))
    //     }

    //     // console.log("Start");
    //     // console.log(newAmount);
    //     // console.log(expiresBy);
    //     // console.log(signature[0]);
    //     // console.log(signature[1]);
    //     // console.log(aIndex);
    //     // console.log(bIndex);
    //     // console.log("End");

    //     bytes32 rKey = recordKey(aIndex, bIndex);
    //     Record memory record = records[rKey];

    //     if (
    //         record.amount >= newAmount ||
    //         record.fixedAfter <= block.timestamp ||
    //         expiresBy % duration != 0 
    //     ){
    //         revert();
    //     }

    //     // validate signature
    //     uint256[2] memory hash = msgHashBLS(aIndex, bIndex, newAmount, expiresBy, record.seqNo);
    //     // FIXME aggregate public keys into one
    //     uint256[4][] memory publicKeys = new uint256[4][](2);
    //     publicKeys[0] = blsPublicKeys[aIndex];
    //     publicKeys[1] = blsPublicKeys[bIndex];
    //     uint256[2][] memory messages = new uint256[2][](2);
    //     messages[0] = hash;
    //     messages[1] = hash;
    //     (bool result, bool success) = BLS.verifyMultiple(signature, publicKeys, messages);
    //     if (!result || !success){
    //         revert();
    //     }

    //     // update accounts
    //     uint128 amountDiff = newAmount - record.amount;
    //     record.amount = newAmount;
    //     Account memory bAccount = accounts[bIndex];
    //     if (bAccount.balance < amountDiff){
    //         // slash `b` only if they were not
    //         // slashed for `seqNo` before
    //         if (!record.slashed){
    //             record.slashed = true;
    //             securityDeposits[bIndex] = 0;
    //         }

    //         amountDiff = bAccount.balance;
    //         bAccount.balance = 0;
    //     }else {
    //         bAccount.balance -= amountDiff;
    //     }

    //     accounts[bIndex] = bAccount;

    //     Account memory aAccount = accounts[aIndex];
    //     aAccount.balance += amountDiff;
    //     accounts[aIndex] = aAccount;

    //     // update record
    //     record.fixedAfter = uint32(block.timestamp + bufferPeriod);
    //     records[rKey] = record;
    // }


}
