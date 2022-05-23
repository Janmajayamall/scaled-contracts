import "@nomiclabs/hardhat-ethers";

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
	paths: { cache: "./hh_cache", tests: "./src/test" },
	gasReporter: {
		enabled: true,
	},
};
