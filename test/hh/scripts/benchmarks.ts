import { ethers } from 'hardhat';
import { solG1, solG2, aggregateRaw } from '@thehubbleproject/bls/dist/mcl';
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
} from '../helpers';
import { asL2Provider } from '@eth-optimism/sdk';
import { util } from 'chai';

const l2Url = 'https://mainnet.optimism.io';
const providerL2 = asL2Provider(new ethers.providers.JsonRpcProvider(l2Url));

const noOfReceipts = 200;

/// To estimate how cost of calling `post()` function increases
/// with no. of receipts.
async function main() {
  let mainSigner = (await ethers.getSigners())[0];
  const users = await setUpUsers(noOfReceipts + 1, mainSigner);
  const testToken = await deployToken(mainSigner);
  const stateBLS = await deployStateBLS(testToken, mainSigner);

  // normal setup
  const fundAmount = BigNumber.from('340282366920938463463374607431768211455'); // max amount ~ 128 bits
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

  let postNonceSig = users[0].blsSigner.sign(
    utils.solidityPack(['uint32'], [1])
  );
  const calldata = preparePostCalldata(
    postNonceSig,
    updates,
    users[0].index,
    utils.arrayify(stateBLS.interface.getSighash('post()'))
  );

  const tx = await users[0].wallet.populateTransaction({
    data: calldata,
    to: stateBLS.address,
    value: 0,
  });
  console.log(tx, ' tx');

  // send the tx
  const res = await users[0].wallet.sendTransaction(tx);

  // print details
  let l1GasUnits = await providerL2.estimateL1Gas(tx);
  let l1GasPrice = BigNumber.from('29050458313');
  let l1GasCost = l1GasPrice
    .mul(l1GasUnits)
    .mul(BigNumber.from('12400000'))
    .div(BigNumber.from('10000000'));
  let l2GasUnits = res.gasLimit;
  let l2GasCost = l2GasUnits.mul(BigNumber.from('1000000'));
  console.log(`L1 Gas Units: ${l1GasUnits}`);
  console.log(`L1 Gas price: ${l1GasPrice} Wei`);
  console.log(`L1 Gas cost: ${l1GasCost} Wei`);
  console.log(`L2 Gas Units: ${l2GasUnits}`);
  console.log(`L2 Gas cost: ${l2GasCost} Wei`);
  console.log(`Total: ${l2GasCost.add(l1GasCost)} Wei`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
