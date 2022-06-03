
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "ds-test/test.sol";
import "./../contracts/StateL2.sol";
import "./../contracts/StateBLS.sol";
import "./TestToken.sol";
import "./utils/Console.sol";
import {BlsUtils} from "./utils/BlsUtils.sol";
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

    // `a` is the service provider.
    // We assume that `a` is the one agggregating all receipts
    // and posting them onchain.
    uint256 aPvKey = 0x084154b85f5eec02a721fcfe220e4e871a2c35593c2a46292ad53b8f793c8360;
    address aAddress;

    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // users are service requesters
    uint256[] usersPvKey;
    address[] usersAddress;

    User[] users;
    bytes32 constant blsDomain = keccak256(abi.encodePacked("test"));
 
    StateL2 stateL2;
    StateBLS stateBls;
    TestToken token;
    

    // Configs
    uint256 usersCount = 2;
    uint128 fundAmount = 10000 * 10 ** 18;
    // amount = 3899.791821921342121326
    uint128 dummyCharge = 3899791821921342121326;

    // https://public-grafana.optimism.io/d/9hkhMxn7z/public-dashboard?orgId=1&refresh=5m
    uint256 optimismL1GasPrice = 45;

    function setUsers(uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            uint256 pvKey;
            uint256[4] memory blsPubKey;
            (pvKey, blsPubKey) = BlsUtils.genUser();

            // console.log(secret, "secret");
            // BlsUtils.blsPubKey(secret);

            User memory u = User({
                pvKey: pvKey,
                blsPubKey: blsPubKey,
                addr: vm.addr(pvKey),
                index: 0
            });
            
            users.push(u);
        }
    }

    function registerUser(User memory user) internal {

    }

    function setUp() public {
        setUsers(usersCount);

        token = new TestToken(
            "TestToken",
            "TT",
            18
        );


        stateBls = new StateBLS(address(token));

        registerUsers();
        fundUsers(fundAmount);
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

    function printBalances() internal view {
        console.log("a's balance: ", stateL2.getAccount(1).balance);
        for (uint64 i = 0; i < usersAddress.length; i++) {
            console.log(usersAddress[i], "'s balance: ", stateL2.getAccount(i + 2).balance);
        }
    }

    function registerUsers() internal {
        for (uint256 i = 0; i < users.length; i++) {
            // sign address
            User memory user = users[i];
            bytes memory _msg = abi.encodePacked(user.addr);
            uint256[2] memory sig = BlsUtils.blsSign(user.pvKey, blsDomain, _msg);
            stateBls.register(user.addr, user.blsPubKey, sig);  

            // get user's index
            users[i].index = stateBls.userCount();
        }
    }

    function fundUser(User memory user, uint128 amount) internal {
        token.transfer(address(stateBls), amount);        
        stateBls.fundAccount(user.index);
    }

    function fundUsers(uint128 amount) internal {
        for (uint256 i = 0; i < users.length; i++) {
            fundUser(users[i], amount);
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

    function aggregateSignaturesForPost(uint256[2] memory commitSignature, Update[] memory updates) internal returns (uint256[2] memory aggSig) {
        uint256[2][] memory signatures = new uint256[2][](updates.length + 1);
        signatures[0] = commitSignature;
        for (uint256 i = 0; i < updates.length; i++) {
            signatures[i + 1] = updates[i].bSignature;
        }

        aggSig = BlsUtils.aggregateSignatures(signatures);
    }

    function testPost() public {
        Update[] memory updates = new Update[](users.length - 1);
        User memory aUser = users[0];
        uint32 currentCycleExpiry = stateBls.currentCycleExpiry();
        for (uint64 i = 1; i < users.length; i++) {
            // create receipt
            Receipt memory r = Receipt({
                aIndex: aUser.index,
                bIndex: users[i].index,
                amount: dummyCharge,
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

}