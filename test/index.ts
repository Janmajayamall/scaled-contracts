import { assert, expect, use } from 'chai';
import {
  aggregate,
  BlsSignerFactory,
  BlsSignerInterface,
} from '@thehubbleproject/bls/dist/signer';
import { ethers } from 'hardhat';
import { solG1, solG2, aggregateRaw } from '@thehubbleproject/bls/dist/mcl';
import {
  BigNumber,
  utils,
  Transaction,
  Contract,
  Wallet,
  Signer,
} from 'ethers';
import { TransactionRequest } from '@ethersproject/abstract-provider';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { arrayify } from 'ethers/lib/utils';
import { randomBytes, sign } from 'crypto';
import { rootCertificates } from 'tls';
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
} from './hh/helpers';

describe('Tesst1', function () {
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

    const res = await users[0].wallet.sendTransaction(
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
});
