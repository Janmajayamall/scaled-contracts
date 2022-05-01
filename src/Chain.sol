// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "./libraries/smt.sol";

contract Chain {
    struct Receipt {
        address a_address;
        address b_address;
        uint256 a_owes;
        uint256 b_owes;
        uint256 expires_by;
    }

    struct Update {
        bytes32 rootBefore;
        bytes32 rootAfter;
        Receipt receipt;
    }

    struct Account {
        address owner;
        uint256 balance;
    }

    struct SMTCompactProof {
        bytes32 bitmask;
        bytes32[] nodes;
    }

    bytes32 stateRoot;

    function accountHash(Account memory account)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(account.owner, account.balance));
    }

    function accountPath(address accountAddress)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(accountAddress));
    }

    function extendChain(Update[] calldata updates) public {
        // TODO
        // 1. Check that msg.sender has enough  security deposit

        // verify updates are in sequence (i.e. (index - 1).rootAfter == index.rootAfter)
        for (uint256 i = 0; i < updates.length; i++) {
            // update at index 0 should proceed from `stateRoot`
            if (i == 0 && stateRoot != updates[i].rootBefore) {
                revert();
            } else if (updates[i].rootBefore != updates[i - 1].rootAfter) {
                // each subsequent update should build on the
                // previous update.
                revert();
            }

            // check receipt hasn't expired
            if (updates[i].receipt.expires_by <= block.timestamp) {
                revert();
            }
        }

        // update the stateRoot
        stateRoot = updates[updates.length - 1].rootAfter;
    }

    function proveInvalidStateTransition(
        Update memory invalidUpdate,
        address updaterSignature,
        address updaterAddress,
        Account memory aOld,
        Account memory bOld,
        SMTCompactProof memory w1,
        SMTCompactProof memory w2
    ) public {
        // TODO
        // 1. Verify dishonest updater signed the invalid update

        // calculate `aUpdated` and `bUpdated`
        // using `invalidUpdate.receipt`
        Account memory aUpdated = Account({
            owner: aOld.owner,
            balance: aOld.balance +
                invalidUpdate.receipt.b_owes -
                invalidUpdate.receipt.a_owes
        });
        Account memory bUpdated = Account({
            owner: bOld.owner,
            balance: bOld.balance +
                invalidUpdate.receipt.a_owes -
                invalidUpdate.receipt.b_owes
        });

        // verify `w1` in `invalidUpdate.rootBefore`
        bytes32 aOldHash = accountHash(aOld);
        if (
            Smt.verifyCompactProof(
                w1.bitmask,
                w1.nodes,
                invalidUpdate.rootBefore,
                aOldHash,
                accountPath(aOld.owner)
            ) == false
        ) {
            // `w1` is invalid
            revert();
        }

        // update `invalidUpdate.rootBefore` to intermediary state
        // by updating `aOld` to `aUpdated`.
        bytes32 imRoot = Smt.updatedRoot(
            w1.bitmask,
            w1.nodes,
            accountHash(aUpdated),
            accountPath(aOld.owner)
        );

        // verify `w2` in `imRoot`
        bytes32 bOldHash = accountHash(bOld);
        if (
            Smt.verifyCompactProof(
                w2.bitmask,
                w2.nodes,
                imRoot,
                bOldHash,
                accountPath(bOld.owner)
            ) == false
        ) {
            // `w1` is invalid
            revert();
        }

        // update `imRoot` by updating `bOld`
        // to `bUpdated` and check that
        // `new_root == invalidUpdate.rootAfter`.
        //
        // If check fails that means proof for invalid
        // update is correct and user should be slahed
        if (
            Smt.updatedRoot(
                w2.bitmask,
                w2.nodes,
                accountHash(bUpdated),
                accountPath(bOld.owner)
            ) != invalidUpdate.rootAfter
        ) {
            // TODO slash the user
        } else {
            // Decide what to do when proof is invalid
        }
    }
}
