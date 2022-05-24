import "@nomiclabs/hardhat-ethers";
import "hardhat-gas-reporter";

module.exports = {
	defaultNetwork: "hardhat",
	networks: {
		hardhat: {
			chainId: 123,
			throwOnCallFailures: false,
		},
	},
	solidity: {
		version: "0.8.13",
		settings: {
			metadata: {
				bytecodeHash: "none",
			},
			optimizer: {
				enabled: true,
				runs: 200,
			},
			outputSelection: {
				"*": {
					"*": ["metadata"],
				},
			},
		},
	},
	paths: { cache: "./hh_cache" },
	gasReporter: {
		enabled: false,
	},
};
