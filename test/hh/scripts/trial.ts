import { ethers } from 'hardhat';
import * as mcl from 'mcl-wasm';
import { G2 } from 'mcl-wasm';

function getG2(): G2 {
  const g2 = new mcl.G2();
  g2.setStr(
    '1 0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed 0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2 0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa 0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b'
  );
  return g2;
}

async function main2() {
  let secretKey = ethers.utils.hexlify(ethers.utils.randomBytes(32));
  console.log(secretKey);

  await mcl.init(mcl.BN_SNARK1);
  mcl.setMapToMode(mcl.BN254);
  let sFr = new mcl.Fr();
  sFr.setStr(secretKey);
  console.log(sFr);

  let pk = mcl.mul(getG2(), sFr);
  pk.normalize();
  //   console.log(encodeG2Point(pk));
}

async function main1() {
  //   console.log(encodeG2Point(pk));
}

main2()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
