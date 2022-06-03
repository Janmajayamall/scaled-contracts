const { BlsSignerFactory } = require('@thehubbleproject/bls/dist/signer');
const { ethers } = require('ethers');
const args = require('minimist')(process.argv.slice(2));

async function blsSigner(secret, domain) {
  let factory = await BlsSignerFactory.new();
  return factory.getSigner(domain, secret);
}

async function main() {
  if (args['_'][0] == 'random' && args['bytes'] != undefined) {
    let bytes = Number(args['bytes']);
    console.log(ethers.utils.hexlify(ethers.utils.randomBytes(bytes)));
  }

  if (
    args['_'][0] == 'blsSign' &&
    args['secret'] != undefined &&
    args['domain'] != undefined &&
    args['message'] != undefined
  ) {
    let signer = await blsSigner(args['secret'], args['domain']);
    console.log(signer);
  }
}

main()
  .then(() => {})
  .catch((e) => {
    console.log(e);
  });
