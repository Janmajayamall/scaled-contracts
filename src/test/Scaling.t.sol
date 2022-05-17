
// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "ds-test/test.sol";
import "./../State.sol";
import "./../StateL2.sol";
import "./TestToken.sol";
import "./Vm.sol";
import "./Console.sol";

contract Scaling is DSTest {

    struct Receipt {
        address aAddress;
        address bAddress;
        uint128 amount;
        uint16 seqNo;
        uint32 expiresBy;
    }

    struct Update {
        Receipt receipt;
        bytes aSignature;
        bytes bSignature;
    }

    // `a` is the service provider.
    // We assume that `a` is the one agggregating all receipts
    // and posting them onchain.
    uint256 aPvKey = 0x084154b85f5eec02a721fcfe220e4e871a2c35593c2a46292ad53b8f793c8360;
    address aAddress;

    // users are service requesters
    uint256[] usersPvKey;
    address[] usersAddress;
    Update[] updates;

    StateL2 stateL2;
    TestToken token;
    Vm vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function setUsers() internal {
        aAddress = vm.addr(aPvKey);

        // set pv keys
        usersPvKey.push(0x831d7480b61ee56526758a07481b2a9118b31d0344555e60c1b834a74e67c2d9);
        usersPvKey.push(0xde852a66883fca2228e9204dab49836a36140b461971e2054336168ffaf1b5e9);
        usersPvKey.push(0xacc1d30d4404e1b3718806a041041d64ebab8d54dd251b381bfbbe61dac0c598);
        usersPvKey.push(0xa0e474f007a85b9c35a30fd64c42edf4ed5ecda1e6694ec872f31fe1edf06613);
        usersPvKey.push(0x15c9b49e26549f76cab5d52f9ed776105dfa6002e8b1d8858f3ca380abbc32d0);

        // set addresses
        for (uint256 i = 0; i < usersPvKey.length; i++) {
            usersAddress.push(vm.addr(usersPvKey[i]));
        }
    }

    function setUp() public {
        setUsers();

        token = new TestToken(
            "TestToken",
            "TT",
            18
        );

        // mint tokens to `this`
        token.mint(address(this), type(uint256).max);
        stateL2 = new StateL2(address(token));
    }

    function receiptHash(Receipt memory receipt) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    receipt.aAddress,
                    receipt.bAddress,
                    receipt.amount,
                    receipt.seqNo,
                    receipt.expiresBy
                )
            );
    }

    function printBalance(address user) internal view {
        console.log(user, " user's balance: ", stateL2.getAccount(user).balance);
    }

    function printBalances() internal view {
        console.log("a's balance: ", stateL2.getAccount(aAddress).balance);
        for (uint256 i = 0; i < usersAddress.length; i++) {
            console.log(usersAddress[i], "'s balance: ", stateL2.getAccount(usersAddress[i]).balance);
        }
    }

    function registerUsers() internal {
        stateL2.register(aAddress);
        for (uint256 i = 0; i < usersAddress.length; i++) {
            stateL2.register(usersAddress[i]);
        }
    }

    function fundAccount(uint64 index, uint256 amount) internal {
        // transfer token to `state`
        token.transfer(address(stateL2), amount);
        
        // fund `to`'s account in `state`
        stateL2.fundAccount(index);
    }

    function signMsg(bytes32 msgHash, uint256 pvKey) internal returns (bytes memory signature){
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pvKey, msgHash);
        signature = abi.encodePacked(r, s, v);
    }

    function genPostCalldata() internal returns (bytes memory data){
        for (uint256 i = 0; i < updates.length; i++) {
            // console.log("b's index", stateL2.usersIndex(updates[i].receipt.bAddress));
            data = abi.encodePacked(
                data, 
                stateL2.usersIndex(updates[i].receipt.bAddress),
                updates[i].receipt.amount,
                updates[i].aSignature,
                updates[i].bSignature
            );
        }

        data = abi.encodePacked(bytes4(keccak256("post()")), stateL2.usersIndex(aAddress), uint16(updates.length), data);
    }

    function test1() public {
        registerUsers();

        // deposit 100 TT in a's account
        fundAccount(stateL2.usersIndex(aAddress), 100 * 10 ** 18);

        printBalances();
        

        for (uint256 i = 0; i < usersAddress.length; i++) {
            // receipts
            Receipt memory r = Receipt({
                aAddress: aAddress,
                bAddress: usersAddress[i],
                amount: 10 * 10 ** 18,
                seqNo: 1,
                expiresBy: stateL2.currentCycleExpiry()
            });
            bytes32 rHash = receiptHash(r);
            
            Update memory u = Update ({
                receipt: r,
                aSignature: signMsg(rHash, aPvKey),
                bSignature: signMsg(rHash, usersPvKey[i])
            });

            updates.push(u);
        }

        uint256 gasL;
        assembly {
            gasL := gas()
        }
        (bool success, ) = address(stateL2).call(genPostCalldata());
        assembly {
            gasL := sub(gasL, gas())
        }

        console.log("Gas used", gasL);

        assert(success);
        printBalances();
    }



}