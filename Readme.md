# SCALED

Scaled is a off-chain micro-transactions framework that aims to allow for cheap & fast micro-transactions on top Ethereum L2.

## How Scaled works?

Current implementation of Scaled combines time locked commitments, BLS signatures, and cheap execution of L2s to achieve its aim.

For latest implementation details please refer to following [document](https://hackmd.io/PzEMg9btSriAVy2--psmIw).

Prior to the BLS version (which I think is better) ~ I experimented with using SMT (to maintain Account tree that stores user accounts) and fraud proofs to settle time-locked commitments on-chain. You can read implementation details [here](https://hackmd.io/d38J9USRTmO0gVBmxKBbhw). I think BLS version is simpler and better suited for L2s cheap execution cost. It also does not involve having to deal fraud proofs complexity.

I started working on Scaled to enable micro-transactions for DSE (short for decentralized search engine). DSE is a p2p marketplace for information query/retrieval where you can make queries as cheap as few cents + process high volume of queries. Even though I am to develop Scaled as a general framework for micro-transactions, I think it will work great for systems like DSE (ex ~ p2p CDN, file networks, etc.). You can find more about DSE [here](https://github.com/Janmajayamall/dse).
