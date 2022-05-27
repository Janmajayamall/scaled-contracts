import {
  aggregate,
  BlsSignerFactory,
  BlsSignerInterface,
} from '@thehubbleproject/bls/dist/signer';
import { ethers } from 'hardhat';
import { solG1, solG2, aggregateRaw } from '@thehubbleproject/bls/dist/mcl';
import { BigNumber, utils, Contract, Wallet, Signer } from 'ethers';
import { Provider, TransactionRequest } from '@ethersproject/abstract-provider';
import { arrayify } from 'ethers/lib/utils';
import { randomBytes, Sign, sign } from 'crypto';
import { signer } from '@thehubbleproject/bls';

export interface Receipt {
  aIndex: BigNumber;
  bIndex: BigNumber;
  amount: BigNumber;
  expiresBy: BigNumber;
  seqNo: BigNumber;
}

export interface Update {
  receipt: Receipt;
  aSignature: solG1;
  bSignature: solG1;
}

export interface User {
  index: BigNumber;
  wallet: Wallet;
  blsSigner: BlsSignerInterface;
}

export interface OPL1Details {
  gasUnits: number;
  l1DataCostInUsd: number;
}

export async function setUpUsers(
  count: Number,
  mainUser: Signer
): Promise<Array<User>> {
  let users: Array<User> = [];
  const blsSignerFactory = await BlsSignerFactory.new();

  for (let i = 0; i < count; i++) {
    users.push({
      index: BigNumber.from(i + 1),
      wallet: Wallet.createRandom().connect(mainUser.provider!),
      blsSigner: blsSignerFactory.getSigner(blsDomain),
    });

    // fund acc with ether
    await (
      await mainUser.sendTransaction({
        to: users[i].wallet.address,
        value: utils.parseEther('1'),
      })
    ).wait;
  }
  return users;
}

export const blsDomain = arrayify(
  utils.solidityKeccak256(['string'], ['test'])
);

export function receiptHex(r: Receipt): string {
  return utils.solidityPack(
    ['uint64', 'uint64', 'uint128', 'uint32', 'uint16'],
    [r.aIndex, r.bIndex, r.amount, r.expiresBy, r.seqNo]
  );
}

/// User `a` & `b` sign the receipt that they share
/// confirming that `b` owes `a` `r.amount`.
export function getUpdate(a: User, b: User, r: Receipt): Update {
  let rHex = receiptHex(r);
  return {
    receipt: r,
    aSignature: a.blsSigner.sign(rHex),
    bSignature: b.blsSigner.sign(rHex),
  };
}
/// Encodes updates in format required
/// by `post()` fn
export function preparePostCalldata(
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

export function prepareTransaction(
  contract: Contract,
  calldata: Uint8Array
): TransactionRequest {
  return {
    to: contract.address,
    value: BigNumber.from(0),
    data: utils.hexlify(calldata),
  };
}

export async function fundUsers(
  token: Contract,
  stateBLS: Contract,
  users: Array<User>,
  amount: BigNumber,
  mainUser: Signer
) {
  for (let i = 0; i < users.length; i++) {
    // Don't fund `users[0]`
    // since they are `a`
    if (i != 0) {
      await token.connect(mainUser).transfer(stateBLS.address, amount);
      await stateBLS
        .connect(users[i].wallet)
        .fundAccount(BigNumber.from(users[i].index));
    }
  }
}

/// Returns random number with `bytes`
export function getRandomBN(bytes: number): BigNumber {
  return BigNumber.from(`0x${randomBytes(bytes).toString('hex')}`);
}

export async function deployToken(signer: Signer): Promise<Contract> {
  const Token = await ethers.getContractFactory('TestToken', signer);
  return await Token.connect(signer).deploy('TestToken', 'TT', 18);
}

export async function deployStateBLS(
  token: Contract,
  signer: Signer
): Promise<Contract> {
  const StateBLS = await ethers.getContractFactory('StateBLS', signer);
  return await StateBLS.connect(signer).deploy(token.address);
}

export async function registerUsers(users: Array<User>, stateBLS: Contract) {
  for (let i = 0; i < users.length; i++) {
    await stateBLS
      .connect(users[i].wallet)
      .register(users[i].wallet.address, users[i].blsSigner.pubkey);
  }
}

export function calculateOPL1Cost(
  data: Uint8Array,
  gasCostInGwei: number,
  ethPriceInUsd: number
): OPL1Details {
  let gasCostWei = utils.parseUnits(gasCostInGwei.toString(), 9);

  let gasUnits = 0;
  data.forEach((b) => {
    if (b == 0) {
      gasUnits += 4;
    } else {
      gasUnits += 16;
    }
  });

  let costWei = BigNumber.from(gasUnits + 2100).mul(gasCostWei);

  return {
    gasUnits: gasUnits + 2100,
    l1DataCostInUsd: Number(utils.formatEther(costWei)) * 1.25 * ethPriceInUsd,
  };
}

export async function latestBlockWithdrawAfter(
  stateBLS: Contract
): Promise<number> {
  return (
    (await ethers.provider.getBlock('latest')).timestamp +
    (await stateBLS.bufferPeriod())
  );
}

export function recordKey(aIndex: BigNumber, bIndex: BigNumber): string {
  return utils.solidityKeccak256(
    ['uint64', 'string', 'uint64'],
    [aIndex, '++', bIndex]
  );
}
