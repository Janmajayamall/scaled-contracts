
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "ds-test/test.sol";
import "./../contracts/StateL2.sol";
import "./../contracts/StateBLS.sol";
import "./TestToken.sol";
import "./utils/Console.sol";
import {BlsUtils} from "./utils/BLSUtils.sol";
import {BLS} from "./../contracts/libraries/BLS.sol";
import {Vm} from "./utils/Vm.sol";

contract StateL2Test is DSTest {

    struct Receipt {
        uint64 aIndex;
        uint64 bIndex;
        uint128 amount;
        uint16 seqNo;
        uint32 expiresBy;
    }

    struct Update {
        Receipt receipt;
        uint256[2] bSignature;
    }

    struct User {
        uint256 pvKey;
        uint256[4] blsPubKey;
        address addr;
        uint64 index;
    }

    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    bytes32 constant blsDomain = keccak256(abi.encodePacked("test"));

    User[] users;
    
    StateBLS stateBls;
    TestToken token;

    // Configs
    uint128 fundAmount = 10000 * 10 ** 18;


    /// registers a new user to stateBLS contract
    function registerUser(User memory user) internal returns (uint64 userIndex) {
            // sign address
            bytes memory _msg = abi.encodePacked(user.addr);
            uint256[2] memory sig = BlsUtils.blsSign(user.pvKey, blsDomain, _msg);
            stateBls.register(user.addr, user.blsPubKey, sig);  

            // get user's index
            userIndex =  stateBls.userCount();
    }

    /// creates and registers a new user
    function createAndRegisterUser() internal returns (User memory u) {
        (uint256 pvKey, uint256[4] memory blsPubKey) = BlsUtils.genUser();
        u = User({
            pvKey: pvKey,
            blsPubKey: blsPubKey,
            addr: vm.addr(pvKey),
            index: 0
        });

        // register
        u.index = registerUser(u);
    }

    function fundUser(User memory user, uint128 amount) internal {
        token.transfer(address(stateBls), amount);        
        stateBls.fundAccount(user.index);
    }

    /// registers all users in `users`
    function registerUsers() internal {
        for (uint256 i = 0; i < users.length; i++) {
            uint64 userIndex = registerUser(users[i]);
            users[i].index = userIndex;
        }
    }

    /// registers count many new users to `users`
    function createAndRegisterUsers(uint256 count) internal {
        // users = new User[](0);
        for (uint256 i = 0; i < count; i++) {
            User memory u = createAndRegisterUser();
            
            // if user does not exist then push, otherwise replace
            if (users.length <= i) {
                users.push(u);
            }else {
                users[i] = u;
            }
        }
    }

    function fundUsers(uint128 amount) internal {
        for (uint256 i = 0; i < users.length; i++) {
            fundUser(users[i], amount);
        }
    }

    function receiptHash(Receipt memory receipt) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    receipt.aIndex,
                    receipt.bIndex,
                    receipt.amount,
                    receipt.expiresBy,
                    receipt.seqNo
                )
            );
    }


    function printAccountBalances() internal view {
        for (uint i = 0; i < users.length; i++) {
            User memory u = users[i];
            (uint128 balance, ) = stateBls.accounts(u.index);
            console.log(u.index, "'s balance: ", balance);

        }
    }

    
    /// Returns calldata for `post()` fn. All receipts
    /// should have `receipt.aIndex` set as `aIndex`.
    /// `aCommitSignature` is a's signature on `commitmentData`
    /// committing to all `updates`
    function postFnCalldata(uint64 aIndex, uint256[2] memory aggSig,Update[] memory updates) internal returns (bytes memory data){
        for (uint256 i = 0; i < updates.length; i++) {
            // console.log("b's index", stateL2.usersIndex(updates[i].receipt.bAddress));
            data = abi.encodePacked(
                data, 
                uint64(i + 2),
                updates[i].receipt.amount
            );
        }

        data = abi.encodePacked(bytes4(keccak256("post()")), aIndex, uint16(updates.length), aggSig[0], aggSig[1], data);
    }

    /// `aIndex` in all updates receipts should be same 
    /// (i.e. a is posting updates)
    function updateCommitmentBlob(Update[] memory updates) internal returns (bytes memory data){
        for (uint256 i = 0; i < updates.length; i++) {
            // console.log("b's index", stateL2.usersIndex(updates[i].receipt.bAddress));
            data = abi.encodePacked(
                data, 
                updates[i].receipt.bIndex,
                updates[i].receipt.amount,
                updates[i].receipt.seqNo
            );
        }
    }

    function receiptBlob(Receipt memory r) internal returns (bytes memory data) {
        data = abi.encodePacked(r.aIndex, r.bIndex, r.amount, r.expiresBy, r.seqNo);
    }

    /// aggregates a's commitmentData signature and all `b`s signature on
    /// receipt that they share with `a` into one. 
    function aggregateSignaturesForPost(uint256[2] memory commitSignature, Update[] memory updates) internal returns (uint256[2] memory aggSig) {
        uint256[2][] memory signatures = new uint256[2][](updates.length + 1);
        signatures[0] = commitSignature;
        for (uint256 i = 0; i < updates.length; i++) {
            signatures[i + 1] = updates[i].bSignature;
        }

        aggSig = BlsUtils.aggregateSignatures(signatures);
    }

    function setUp() public {
        token = new TestToken(
            "TestToken",
            "TT",
            18
        );
        stateBls = new StateBLS(address(token));
    }

    /// throghout this test we think that `a` is `users[0]`
    function teswwtPost(uint128[11] memory balances, uint128[11] memory amounts) public {
        uint256 usersCount = 11;

        createAndRegisterUsers(usersCount);
        registerUsers();

        // fund users
        for (uint256 i = 0; i < users.length; i++) {
            // skip funding aUser (i.e. users[0])
            if (i != 0){
                fundUser(users[i], balances[i]);
            }
        }

        Update[] memory updates = new Update[](users.length - 1);
        User memory aUser = users[0];
        uint32 currentCycleExpiry = stateBls.currentCycleExpiry();

        uint256 totalAmount; // totalAmount that `a` receives - should not exceed uint128 

        for (uint64 i = 1; i < users.length; i++) {
            // amount = amounts[i] % balances[i]
            uint128 amount;
            if (balances[i] != 0){
                amount = amounts[i] % balances[i];
            }
            
            totalAmount += uint256(amount);

            // create receipt
            Receipt memory r = Receipt({
                aIndex: aUser.index,
                bIndex: users[i].index,
                amount: amount,
                seqNo: 1,
                expiresBy: currentCycleExpiry
            });

            // `b` signs the receipt
            bytes memory _receiptBlob = receiptBlob(r);
            
            Update memory u = Update ({
                receipt: r,
                // we don't need `a`'s signature since they the main user rn
                bSignature:BlsUtils.blsSign(users[i].pvKey, blsDomain, _receiptBlob)
            });

            updates[i-1] = u;
        }

        // if totalAmount > uint128.max then discard
        vm.assume(totalAmount <= type(uint128).max);

        // `a` commits to data
        bytes memory commitBlob = updateCommitmentBlob(updates);
        uint256[2] memory aCommitSig = BlsUtils.blsSign(aUser.pvKey, blsDomain, commitBlob);

        // aggregate a's sig on `commitmentData` and all `b`s
        // signature on their respective receipt that they share
        // with `a`
        uint256[2] memory aggSig = aggregateSignaturesForPost(aCommitSig, updates);

        // generate post() calldata
        bytes memory _calldata = postFnCalldata(aUser.index, aggSig, updates);
        
        (bool success,) = address(stateBls).call(_calldata);
        assert(success);

        // check that a's balance is equal `totalAmount`
        // and other users balance is equal to `balances[i] - (updates[i-1].receipt.amount)`
        for (uint256 i = 0; i < users.length; i++) {
            uint128 expectedBalance;
            if (i == 0){
                expectedBalance = uint128(totalAmount);
            }else {
                expectedBalance = balances[i] - updates[i-1].receipt.amount;
            }

            (uint128 balance, ) = stateBls.accounts(users[i].index);
            assert(balance == expectedBalance);
        }

        // printAccountBalances();

        // printAccountBalances();

        // bytes memory callD = genPostCalldata(updates);
        // // l1 data cost
        // optimismL1Cost(callD);

        // uint256 gasL;
        // assembly {
        //     gasL := gas()
        // }
        // (bool success, ) = address(stateL2).call(callD);
        // assembly {
        //     gasL := sub(gasL, gas())
        // }
        // console.log("Execution gas units:", gasL);
        // assert(success);

        // printBalances();
    }

    function testInitWithdraw() public {
        // create new user
        User memory user = createAndRegisterUser();

        // Since this is user's first withdrawal
        // their exisitng account nonce should be 0.
        // To initWithdraw we sigh exisitng nonce + 1.
        uint32 nonce = 1;
        uint128 withdrawalAmount = 121312121;
        uint256[2] memory sig = BlsUtils.blsSign(user.pvKey, blsDomain, abi.encodePacked(nonce, withdrawalAmount));
        stateBls.initWithdraw(user.index, withdrawalAmount, sig);

        // check pending withdrawl
        (uint128 pendingAmount, uint32 validAfter) = stateBls.pendingWithdrawals(user.index);
        assert(pendingAmount == withdrawalAmount);
        assert(validAfter == block.timestamp + stateBls.bufferPeriod());

        // check user's account nonce is still 0
        (, nonce) = stateBls.accounts(user.index);
        assert(nonce == 0);
    }

    function testInitWithdrawOverrideWithCorrectNonce() public {
        // create new user
        User memory user = createAndRegisterUser();

        // 1st initWithdraw
        uint32 nonce = 1;
        uint128 withdrawalAmount = 21212121;
        uint256[2] memory sig = BlsUtils.blsSign(user.pvKey, blsDomain, abi.encodePacked(nonce, withdrawalAmount));
        stateBls.initWithdraw(user.index, withdrawalAmount, sig);

        // change blocktimestamp
        vm.warp(10);

        // 2nd initWithdraw
        withdrawalAmount = 1213;
        sig = BlsUtils.blsSign(user.pvKey, blsDomain, abi.encodePacked(nonce, withdrawalAmount));
        stateBls.initWithdraw(user.index, withdrawalAmount, sig);

        // check pending withdrawal equal to details of 2nd withdrawl
        (uint128 pendingAmount, uint32 validAfter) = stateBls.pendingWithdrawals(user.index);
        assert(pendingAmount == withdrawalAmount);
        assert(validAfter == block.timestamp + stateBls.bufferPeriod());
    }

    function testFailInitWithdrawIncorrectNonce() public {
        // create new user
        User memory user = createAndRegisterUser();

        // Since this is user's first withdrawal
        // their exisitng account nonce should be 0 
        // and `initWithdraw` should be called with
        // nonce = 1. By setting nonce = 2, we set 
        // an incorrect nonce for which fn should throw
        uint32 nonce = 2;
        uint128 withdrawalAmount = 121312121;
        uint256[2] memory sig = BlsUtils.blsSign(user.pvKey, blsDomain, abi.encodePacked(nonce, withdrawalAmount));
        stateBls.initWithdraw(user.index, withdrawalAmount, sig);
    }

    function testFailInitWithdrawIncorrectSignature() public {
        User memory user = createAndRegisterUser();

        uint32 nonce = 1; // nonce is correct
        uint128 withdrawalAmount = 121312121;
        // notice that we sign on incorrect nonce (i.e. nonce = 0), thus fn call should throw
        uint256[2] memory sig = BlsUtils.blsSign(user.pvKey, blsDomain, abi.encodePacked(nonce - 1, withdrawalAmount));
        stateBls.initWithdraw(user.index, withdrawalAmount, sig);
    }

    function testProcessWithdrawal() public {
        User memory user = createAndRegisterUser();

        // fund user
        uint128 balance = 212912912;
        fundUser(user, balance);

        // initWithdraw
        uint32 nonce = 1; // this will be the first withdrawal 
        uint128 withdrawalAmount = 1411212; // notice that withdrawalAmount < balance
        uint256[2] memory sig = BlsUtils.blsSign(user.pvKey, blsDomain, abi.encodePacked(nonce, withdrawalAmount));
        stateBls.initWithdraw(user.index, withdrawalAmount, sig);

        // wrap blocktime to `block.timestamp + stateBls.bufferPeriod() + 1`
        // for withdrawal buffer period to pass
        vm.warp(block.timestamp + stateBls.bufferPeriod() + 1);

        // process withdrawal
        uint256 tokenBalanceBefore = token.balanceOf(user.addr);
        stateBls.processWithdrawal(user.index);
        uint256 tokenBalanceAfter = token.balanceOf(user.addr);
        // check that user received amount in `token`
        assert(tokenBalanceBefore + withdrawalAmount == tokenBalanceAfter);

        // check user's account.balance = balance - withdrawalAmount
        // & accont.nonce = nonce (i.e. 1)
        (uint128 accBalance, uint32 accNonce) = stateBls.accounts(user.index);
        assert(accBalance == balance - withdrawalAmount);
        assertEq(accNonce, nonce);

        // check pending withdrawal no more exists
        (uint128 pendingAmount, uint32 validAfter) = stateBls.pendingWithdrawals(user.index);
        assert(pendingAmount == 0);
        assert(validAfter == 0);
    }

    function testFailProcessWithdrawalWithoutInit() public {
        User memory user = createAndRegisterUser();
        stateBls.processWithdrawal(user.index);
    }

    function testFailProcessWithdrawalMoreThanBalance() public {
        User memory user = createAndRegisterUser();
        
        uint128 balance = 212912912;
        fundUser(user, balance);

        // initWithdraw
        uint32 nonce = 1; // this will be the first withdrawal 
        uint128 withdrawalAmount = balance + 1; // withdrawalAmount is greater than balance
        uint256[2] memory sig = BlsUtils.blsSign(user.pvKey, blsDomain, abi.encodePacked(nonce, withdrawalAmount));
        stateBls.initWithdraw(user.index, withdrawalAmount, sig);

        // process withdrawal
        stateBls.processWithdrawal(user.index);
    }
}