// import { asL2Provider } from '@eth-optimism/sdk';
// import { Wallet } from 'ethers';
// import { ethers } from 'hardhat';
// import { deployStateBLS, deployToken } from '../helpers';

// const l2Url = 'http://135.181.45.48:8545/';

// async function main() {
//   const signer = getL2Signer(l2Url);

//   const token = await deployToken(signer);
//   const stateBls = await deployStateBLS(token, signer);
//   console.log(stateBls.address, token.address);
// }

// main()
//   .then(() => process.exit(0))
//   .catch((error) => {
//     console.error(error);
//     process.exit(1);
//   });
