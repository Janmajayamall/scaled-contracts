# SCALED

Scaled is a off-chain micro-transactions framework that aims to allow for cheap & fast micro-transactions on top Ethereum L2.

## How Scaled works?

Current implementation of Scaled combines time locked commitments, BLS signatures, and cheap execution of L2s to achieve its aim.

For latest implementation details please refer to following [document](https://hackmd.io/PzEMg9btSriAVy2--psmIw).

An alternative to BLS version is using SMT (to maintain Account tree that stores user accounts) and fraud proofs to settle time-locked commitments on-chain. You can read details [here](https://hackmd.io/d38J9USRTmO0gVBmxKBbhw). Using BLS is preferred over SMT + fraud proofs because of simplicity & better suitability for L2s.

Scaled started as a necessary component for [DSE](https://github.com/Janmajayamall/dse). It aims to be usable as a plugin payment layer by DSE as well as other such applications ~ incentivised p2p CDNs, file transfer, etc.
