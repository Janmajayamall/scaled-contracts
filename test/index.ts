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

describe('Tesst1', function () {
  const blsDomain = arrayify(utils.solidityKeccak256(['string'], ['test']));

  interface Receipt {
    aIndex: BigNumber;
    bIndex: BigNumber;
    amount: BigNumber;
    expiresBy: BigNumber;
    seqNo: BigNumber;
  }

  interface Update {
    receipt: Receipt;
    aSignature: solG1;
    bSignature: solG1;
  }

  interface User {
    index: BigNumber;
    wallet: Wallet;
    blsSigner: BlsSignerInterface;
  }

  async function setUpUsers(count: Number): Promise<Array<User>> {
    let users: Array<User> = [];
    const blsSignerFactory = await BlsSignerFactory.new();
    const main = (await ethers.getSigners())[0];

    for (let i = 0; i < count; i++) {
      users.push({
        index: BigNumber.from(4294967296 + i + 1),
        wallet: Wallet.createRandom().connect(ethers.provider),
        blsSigner: blsSignerFactory.getSigner(blsDomain),
      });

      // fund acc with ether
      main.sendTransaction({
        to: users[i].wallet.address,
        value: utils.parseEther('1'),
      });
    }
    return users;
  }

  function receiptHex(r: Receipt): string {
    return utils.solidityPack(
      ['uint64', 'uint64', 'uint128', 'uint32', 'uint16'],
      [r.aIndex, r.bIndex, r.amount, r.expiresBy, r.seqNo]
    );
  }

  /// User `a` & `b` sign the receipt that they share
  /// confirming that `b` owes `a` `r.amount`.
  function getUpdate(a: User, b: User, r: Receipt): Update {
    let rHex = receiptHex(r);
    return {
      receipt: r,
      aSignature: a.blsSigner.sign(rHex),
      bSignature: b.blsSigner.sign(rHex),
    };
  }

  /// Encodes updates in format required
  /// by `post()` fn
  function preparePostCalldata(
    updates: Array<Update>,
    aIndex: BigNumber,
    fnSelector: Uint8Array
  ): Uint8Array {
    // aggregate signatures
    let sigs: solG1[] = [];
    updates.forEach((u) => {
      sigs.push(u.aSignature);
      sigs.push(u.bSignature);
    });
    let aggSig = aggregate(sigs);

    let calldata = new Uint8Array([
      ...fnSelector,
      ...utils.arrayify(utils.solidityPack(['uint64'], [aIndex])),
      ...utils.arrayify(utils.solidityPack(['uint16'], [updates.length])),
      ...utils.arrayify(
        utils.solidityPack(['uint256', 'uint256'], [aggSig[0], aggSig[1]])
      ),
    ]);

    updates.forEach((u) => {
      calldata = new Uint8Array([
        ...calldata,
        ...utils.arrayify(
          utils.solidityPack(
            ['uint64', 'uint128'],
            [u.receipt.bIndex, u.receipt.amount]
          )
        ),
      ]);
    });

    return calldata;
  }

  function prepareTransaction(
    contract: Contract,
    calldata: Uint8Array
  ): TransactionRequest {
    return {
      to: contract.address,
      value: BigNumber.from(0),
      data: utils.hexlify(calldata),
    };
  }

  async function fundUsers(
    token: Contract,
    stateBLS: Contract,
    users: Array<User>,
    amount: BigNumber
  ) {
    const main = (await ethers.getSigners())[0];
    for (let i = 0; i < users.length; i++) {
      // Don't fund `users[0]`
      // since they are `a`
      if (i != 0) {
        await token.connect(main).transfer(stateBLS.address, amount);
        await stateBLS
          .connect(users[i].wallet)
          .fundAccount(BigNumber.from(users[i].index));
      }
    }
  }

  /// Returns random number with `bytes`
  function getRandomBN(bytes: number): BigNumber {
    return BigNumber.from(`0x${randomBytes(bytes).toString('hex')}`);
  }

  async function deployToken(): Promise<Contract> {
    const Token = await ethers.getContractFactory('TestToken');
    return await Token.connect((await ethers.getSigners())[0]).deploy(
      'TestToken',
      'TT',
      18
    );
  }

  async function deployStateBLS(token: Contract): Promise<Contract> {
    const StateBLS = await ethers.getContractFactory('StateBLS');
    return await StateBLS.deploy(token.address);
  }

  async function registerUsers(users: Array<User>, stateBLS: Contract) {
    for (let i = 0; i < users.length; i++) {
      await stateBLS
        .connect(users[i].wallet)
        .register(users[i].wallet.address, users[i].blsSigner.pubkey);
    }
  }

  function calculateOPL1Cost(data: Uint8Array): Number {
    let gasCostWei = utils.parseUnits('30', 9);
    let ethUSD = 3000;

    let gasUnits = 0;
    data.forEach((b) => {
      if (b == 0) {
        gasUnits += 4;
      } else {
        gasUnits += 16;
      }
    });

    console.log('Calldata Gas Units:', gasUnits);

    let costWei = BigNumber.from(gasUnits + 2100).mul(gasCostWei);
    console.log('Calldata Cost Wei', costWei);

    return Number(utils.formatEther(costWei)) * 1.25 * ethUSD;
  }

  async function latestBlockWithdrawAfter(stateBLS: Contract): Promise<number> {
    return (
      (await ethers.provider.getBlock('latest')).timestamp +
      (await stateBLS.bufferPeriod())
    );
  }

  function recordKey(aIndex: BigNumber, bIndex: BigNumber): string {
    return utils.solidityKeccak256(
      ['uint64', 'string', 'uint64'],
      [aIndex, '++', bIndex]
    );
  }

  // Imagine users[0] as `a` (i.e. the service provider)
  // with which rest of the users interact and pay overtime.
  // users[0] maintains a receipt with each of them and `post`s
  // them on-chain once in a while.
  it('should settle', async function () {
    const users = await setUpUsers(3);
    const testToken = await deployToken();
    const stateBLS = await deployStateBLS(testToken);

    // normal setup
    const fundAmount = BigNumber.from(
      '340282366920938463463374607431768211455'
    ); // max amount ~ 128 bits
    await registerUsers(users, stateBLS);
    await fundUsers(testToken, stateBLS, users, fundAmount);

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

  //   it('Estimate cost', async function () {
  //     const users = await setUpUsers(100);
  //     const testToken = await deployToken();
  //     const stateBLS = await deployStateBLS(testToken);

  //     const currentCycle = await stateBLS.currentCycleExpiry();

  //     // fund wallets
  //     const amount = utils.parseUnits('1000', 18);
  //     await fundUsers(testToken, stateBLS, users, amount);

  //     // test post()
  //     let updates: Update[] = [];
  //     users.forEach((u, index) => {
  //       // user at index 0 is `a`
  //       if (index != 0) {
  //         let r: Receipt = {
  //           aIndex: users[0].index,
  //           bIndex: u.index,
  //           amount: getRandomBN(16),
  //           expiresBy: BigNumber.from(currentCycle),
  //           seqNo: BigNumber.from(1),
  //         };
  //         updates.push(getUpdate(users[0], u, r));
  //       }
  //     });
  //     const calldata = preparePostCalldata(
  //       updates,
  //       users[0].index,
  //       utils.arrayify(stateBLS.interface.getSighash('post()'))
  //     );

  //     console.log('OP L1 data cost in USD: ', calculateOPL1Cost(calldata));

  //     // await stateBLS.provider.call(prepareTransaction(stateBLS, calldata));
  //   });
});
