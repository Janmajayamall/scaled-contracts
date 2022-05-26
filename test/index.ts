import { expect, use } from "chai";
import {
	aggregate,
	BlsSignerFactory,
	BlsSignerInterface,
} from "@thehubbleproject/bls/dist/signer";
import { ethers } from "hardhat";
import { solG1, solG2, aggregateRaw } from "@thehubbleproject/bls/dist/mcl";
import { BigNumber, utils, Transaction, Contract, Wallet } from "ethers";
import { TransactionRequest } from "@ethersproject/abstract-provider";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { arrayify } from "ethers/lib/utils";
import { randomBytes } from "crypto";

describe("Tesst1", function () {

	interface Receipt {
		aIndex: BigNumber;
		bIndex: BigNumberz;
		amount: BigNumber;
		expiresBy: BigNumber;
		seqNo: BigNumber;
	}

	interface Update {
		receipt: Receipt;
		aSignature: solG1;
		bSignature: solG1;
	}

	interface User {
		index: BigNumber;
		wallet: Wallet;
		blsSigner: BlsSignerInterface;
	}

	async function setUp(
		count: Number,
		factory: BlsSignerFactory
	): Promise<Array<User>> {
		const domain = arrayify(utils.solidityKeccak256(["string"], ["test"]));
		let users: Array<User> = [];

		const first = (await ethers.getSigners())[0];

		for (let i = 0; i < count; i++) {
			users.push({
				index: BigNumber.from(4294967296 + i + 1),
				wallet: Wallet.createRandom().connect(ethers.provider),
				blsSigner: factory.getSigner(domain),
			});

			first.sendTransaction({
				to: users[i].wallet.address,
				value: utils.parseEther("1"),
			});
		}
		return users;
	}

	function receiptHex(r: Receipt): string {
		return utils.solidityPack(
			["uint64", "uint64", "uint128", "uint32", "uint16"],
			[r.aIndex, r.bIndex, r.amount, r.expiresBy, r.seqNo]
		);
	}

	function getUpdate(a: User, b: User, r: Receipt): Update {
		let rHex = receiptHex(r);
		return {
			receipt: r,
			aSignature: a.blsSigner.sign(rHex),
			bSignature: b.blsSigner.sign(rHex),
		};
	}

	function preparePostCalldata(
		updates: Array<Update>,
		aIndex: BigNumber
	): Uint8Array {
		// aggregate signatures
		let sigs: solG1[] = [];
		updates.map((u) => {
			sigs.push(u.aSignature);
			sigs.push(u.bSignature);
		});
		let aggSig = aggregate(sigs);

		let calldata = new Uint8Array([
			// index of `a` is 1
			...utils.arrayify(utils.solidityPack(["uint64"], [aIndex])),
			...utils.arrayify(utils.solidityPack(["uint16"], [updates.length])),
			...utils.arrayify(
				utils.solidityPack(
					["uint256", "uint256"],
					[aggSig[0], aggSig[1]]
				)
			),
		]);

		updates.forEach((u) => {
			calldata = new Uint8Array([
				...calldata,
				...utils.arrayify(
					utils.solidityPack(
						["uint64", "uint128"],
						[u.receipt.bIndex, u.receipt.amount]
					)
				),
			]);
		});

		return calldata;
	}

	function prepareTransaction(
		contract: Contract,
		calldata: Uint8Array
	): TransactionRequest {
		return {
			to: contract.address,
			chainId: 123,
			nonce: 1,
			gasLimit: BigNumber.from(20000000),
			value: BigNumber.from(0),
			data: utils.hexlify(calldata),
		};
	}

	async function fundUsers(
		token: Contract,
		state: Contract,
		users: Array<User>
	) {
		let amount = utils.parseUnits("100000000", 18);
		for (let i = 0; i < users.length; i++) {
			await token
				.connect(users[0].wallet)
				.transfer(users[i].wallet.address, amount);
			await state
				.connect(users[i].wallet)
				.fundAccount(BigNumber.from(users[i].index));
		}
	}

	function getRandomBN(bytes: number): BigNumber {
		return BigNumber.from(`0x${randomBytes(bytes).toString("hex")}`);
	}

	function calculateOPL1Cost(data: Uint8Array): Number {
		let gasCostWei = utils.parseUnits("30", 9);
		let ethUSD = 3000;

		let gasUnits = 0;
		data.forEach((b) => {
			if (b == 0) {
				gasUnits += 4;
			} else {
				gasUnits += 16;
			}
		});

		console.log("Calldata Gas Units:", gasUnits);

		let costWei = BigNumber.from(gasUnits + 2100).mul(gasCostWei);
		console.log("Calldata Cost Wei", costWei);

		return Number(utils.formatEther(costWei)) * 1.25 * ethUSD;
	}



	it("Estimate cost", async function () {
		
		const blsSignerFactory = await BlsSignerFactory.new();
		const users = await setUp(100, blsSignerFactory);
		const Token = await ethers.getContractFactory(
			"TestToken",
			users[0].wallet
		);
		const testToken = await Token.connect(users[0].wallet).deploy(
			"TestToken",
			"TT",
			18
		);

		const StateBLS = await ethers.getContractFactory("StateBLS");
		const stateBLS = await StateBLS.deploy(testToken.address);

		const currentCycle = await stateBLS.currentCycleExpiry();
		console.log(currentCycle, "Current Cycle");

		// register users
		for (let i = 0; i < users.length; i++) {
			await stateBLS
				.connect(users[i].wallet)
				.register(users[i].wallet.address, users[i].blsSigner.pubkey);
		}

		// fund wallets
		await fundUsers(testToken, stateBLS, users);

		// test post()
		let updates: Update[] = [];
		users.forEach((u, index) => {
			// user at index 0 is `a`
			if (index != 0) {
				let r: Receipt = {
					aIndex: users[0].index,
					bIndex: u.index,
					amount: getRandomBN(16),
					expiresBy: BigNumber.from(currentCycle),
					seqNo: BigNumber.from(1),
				};
				updates.push(getUpdate(users[0], u, r));
			}
		});
		let calldata = preparePostCalldata(updates, users[0].index);
		calldata = new Uint8Array([
			...utils.arrayify(stateBLS.interface.getSighash("post()")),
			...calldata,
		]);

		console.log("OP L1 data cost in USD: ", calculateOPL1Cost(calldata));

		await stateBLS.provider.call(prepareTransaction(stateBLS, calldata));
	});
});
