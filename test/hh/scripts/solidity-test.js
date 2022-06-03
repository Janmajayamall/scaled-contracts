const mcl = require('mcl-wasm');
const { toBigEndian } = require('@thehubbleproject/bls/dist/mcl');
const { BlsSignerFactory } = require('@thehubbleproject/bls/dist/signer');
const { ethers, utils } = require('ethers');
const { hexlify } = require('ethers/lib/utils');
const args = require('minimist')(process.argv.slice(2));

async function blsSigner(secret, domain) {
  let factory = await BlsSignerFactory.new();
  return factory.getSigner(domain, secret);
}

function getG2() {
  const g2 = new mcl.G2();
  g2.setStr(
    '1 0x1800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed 0x198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c2 0x12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa 0x090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b'
  );
  return g2;
}

function encodeG2Point(p) {
  p.normalize();
  let x = toBigEndian(p.getX());
  let y = toBigEndian(p.getY());
  let x0 = hexlify(x.slice(32));
  let x1 = hexlify(x.slice(0, 32));
  let y0 = hexlify(y.slice(32));
  let y1 = hexlify(y.slice(0, 32));
  return [x0, x1, y0, y1];
}

async function genUser() {
  await mcl.init(mcl.BN_SNARK1);
  mcl.setMapToMode(mcl.BN254);

  let secretKey = ethers.utils.hexlify(ethers.utils.randomBytes(31));

  let sFr = new mcl.Fr();
  sFr.setStr(secretKey);
  let pk = mcl.mul(getG2(), sFr);
  pk.normalize();
  [x0, x1, y0, y1] = encodeG2Point(pk);

  let data = utils.solidityPack(
    ['uint256', 'uint256', 'uint256', 'uint256', 'uint256'],
    [secretKey, x0, x1, y0, y1]
  );
  console.log(data);
}

async function main() {
  if (args['_'][0] == 'random' && args['bytes'] != undefined) {
    let bytes = Number(args['bytes']);
    console.log(ethers.utils.hexlify(ethers.utils.randomBytes(bytes)));
  }

  if (args['_'][0] == 'genUser') {
    await genUser();
  }

  if (args['_'][0] == 'blsPubKey' && args['secret'] != undefined) {
  }
}

main()
  .then(() => {})
  .catch((e) => {
    console.log(e);
  });
