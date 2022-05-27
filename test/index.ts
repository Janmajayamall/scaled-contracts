import { assert, expect, use, util } from 'chai';
import { ethers } from 'hardhat';

import { BigNumber, utils } from 'ethers';
import {
  User,
  Receipt,
  Update,
  setUpUsers,
  deployStateBLS,
  deployToken,
  registerUsers,
  fundUsers,
  getRandomBN,
  getUpdate,
  preparePostCalldata,
  prepareTransaction,
  latestBlockWithdrawAfter,
  recordKey,
  receiptHex,
  prepareCorrectUpdateCalldata,
} from './hh/helpers';

describe('Main tests', function () {
  // Imagine users[0] as `a` (i.e. the service provider)
  // with which rest of the users interact and pay overtime.
  // users[0] maintains a receipt with each of them and `post`s
  // them on-chain once in a while.
  it('should settle', async function () {
    let mainSigner = (await ethers.getSigners())[0];
    const users = await setUpUsers(3, mainSigner);
    const testToken = await deployToken(mainSigner);
    const stateBLS = await deployStateBLS(testToken, mainSigner);

    // normal setup
    const fundAmount = BigNumber.from(
      '340282366920938463463374607431768211455'
    ); // max amount ~ 128 bits
    await registerUsers(users, stateBLS);
    await fundUsers(testToken, stateBLS, users, fundAmount, mainSigner);

    // This is cycle we target after which all receipts
    // expire
    const currentCycle = await stateBLS.currentCycleExpiry();

    let updates: Array<Update> = [];
    users.forEach((u, index) => {
      // since users[0] is `a` it can't have a receipt
      // with themselves
      if (index != 0) {
        let r: Receipt = {
          aIndex: users[0].index,
          bIndex: u.index,
          // 16 bytes is max ~ keeping it 15 to avoid overflow errors
          amount: getRandomBN(15),
          expiresBy: BigNumber.from(currentCycle),
          seqNo: BigNumber.from(1),
        };
        updates.push(getUpdate(users[0], u, r));
      }
    });

    const calldata = preparePostCalldata(
      updates,
      users[0].index,
      utils.arrayify(stateBLS.interface.getSighash('post()'))
    );

    await users[0].wallet.sendTransaction(
      prepareTransaction(stateBLS, calldata)
    );

    // total amount paid to users[0]
    let totalAmount = BigNumber.from('0');
    updates.forEach((u) => {
      totalAmount = totalAmount.add(u.receipt.amount);
    });

    const wAfter = await latestBlockWithdrawAfter(stateBLS);

    // check user balances
    for (let i = 0; i < users.length; i++) {
      let account = await stateBLS.accounts(users[i].index);

      if (i == 0) {
        // users[0] balance should `totalAmount`
        assert(totalAmount.eq(account['balance']));

        // withdrawAfter should be zero for users[0]
        // since they are `a`
        assert(account['withdrawAfter'] == 0);
      } else {
        // users[i] balance should be `fundAmount-updates[i].r.amount`
        assert(
          account['balance'].eq(fundAmount.sub(updates[i - 1].receipt.amount))
        );

        // withdrawAfter should be
        assert(account['withdrawAfter'] == wAfter);
      }
    }

    // check records
    for (let i = 0; i < users.length; i++) {
      if (i != 0) {
        let rKey = recordKey(users[0].index, users[i].index);
        let record = await stateBLS.records(rKey);

        assert(record['amount'].eq(updates[i - 1].receipt.amount));
        assert(record['seqNo'] == 1);
        assert(record['fixedAfter'] == wAfter);
        assert(record['slashed'] == false);
      }
    }
  });

  /// Consider we have 3 users - users[0] (`a`), users[1] (`b`), users[2] (`b1`)
  /// a posts the receipt that it shares with b & b1, but cheats by posting not the
  /// latest receipt that is shares by `b`.
  /// Now `b` corrects the update by posting the correct receipt-on chain.
  ///
  /// This test is just to check `correctUpdate()` fn and the scenario described
  /// isn't practical since `a` would never post an old receipt over the latest one
  /// because latest receipts always have greater amount than old ones.
  ///
  /// `a` can try to double slash `b` if they don't have sufficient funds even for
  /// an old receipt ~ by posting old receipt first & then calling `correctUpdate()`.
  /// To avoid this, before slashing, we always check whether `b` has been slashed for a receipt with same
  /// seq before shared with same `a`.
  it('should correct update', async function () {
    let mainSigner = (await ethers.getSigners())[0];
    // only three users. users[0] is `a`
    const users = await setUpUsers(3, mainSigner);
    const testToken = await deployToken(mainSigner);
    const stateBLS = await deployStateBLS(testToken, mainSigner);

    // This is cycle we target after which all receipts
    // expire
    const currentCycle = await stateBLS.currentCycleExpiry();

    // normal setup
    const fundAmount = BigNumber.from(
      '340282366920938463463374607431768211455'
    ); // max amount ~ 128 bits
    await registerUsers(users, stateBLS);
    await fundUsers(testToken, stateBLS, users, fundAmount, mainSigner);

    // post updates
    let updates: Array<Update> = [];
    users.forEach((u, index) => {
      // since users[0] is `a` it can't have a receipt
      // with themselves
      if (index != 0) {
        let r: Receipt = {
          aIndex: users[0].index,
          bIndex: u.index,
          amount: BigNumber.from(1000),
          expiresBy: BigNumber.from(currentCycle),
          seqNo: BigNumber.from(1),
        };
        updates.push(getUpdate(users[0], u, r));
      }
    });
    let calldata = preparePostCalldata(
      updates,
      users[0].index,
      utils.arrayify(stateBLS.interface.getSighash('post()'))
    );
    await users[0].wallet.sendTransaction(
      prepareTransaction(stateBLS, calldata)
    );

    // prepare the latest receipt between users[0] & users[1] with amount greater than 1000
    let correctUpdate = getUpdate(users[0], users[1], {
      aIndex: users[0].index,
      bIndex: users[1].index,
      // Note latest receipt for a `seqNo` is the receipt that has the highest amount
      amount: BigNumber.from(1001),
      expiresBy: BigNumber.from(currentCycle),
      seqNo: BigNumber.from(1),
    });

    calldata = prepareCorrectUpdateCalldata(
      correctUpdate,
      utils.arrayify(stateBLS.interface.getSighash('correctUpdate()'))
    );
    await users[0].wallet.sendTransaction(
      prepareTransaction(stateBLS, calldata)
    );

    // account balance of users[0] should be now 2000 + 1, since amount diff in
    // latest receipt is of only 1
    let account = await stateBLS.accounts(users[0].index);
    assert(account['balance'].eq(BigNumber.from(2001)));

    // account balance of users[1] should be `fundAmount - 1001`
    account = await stateBLS.accounts(users[1].index);
    assert(account['balance'].eq(fundAmount.sub(BigNumber.from(1001))));
  });
});
