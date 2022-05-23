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

describe("Tesst1", function () {
	interface Receipt {
		aIndex: BigNumber;
		bIndex: BigNumber;
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
		wallet: SignerWithAddress;
		blsSigner: BlsSignerInterface;
	}

	async function setUp(
		count: Number,
		factory: BlsSignerFactory
	): Promise<Array<User>> {
		console.log("domain: ", utils.solidityKeccak256(["string"], ["test"]));
		const domain = arrayify(utils.solidityKeccak256(["string"], ["test"]));
		let users: Array<User> = [];

		for (let i = 0; i < count; i++) {
			let w = (await ethers.getSigners())[i];
			users.push({
				index: BigNumber.from(i + 1),
				wallet: w,
				blsSigner: factory.getSigner(domain),
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

	function preparePostCalldata(updates: Array<Update>): Uint8Array {
		// aggregate signatures
		let sigs: solG1[] = [];
		updates.map((u) => {
			sigs.push(u.aSignature);
			sigs.push(u.bSignature);
		});
		let aggSig = aggregate(sigs);

		let calldata = new Uint8Array([
			// index of `a` is 1
			...utils.arrayify(utils.solidityPack(["uint64"], [1])),
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
			gasLimit: BigNumber.from(2000000),
			value: BigNumber.from(0),
			data: utils.hexlify(calldata),
		};
	}

	async function fundUsers(
		token: Contract,
		state: Contract,
		users: Array<User>
	) {
		let amount = utils.parseUnits("100", 18);
		for (let i = 0; i < users.length; i++) {
			await token
				.connect(users[0].wallet)
				.transfer(users[i].wallet.address, amount);
			await state
				.connect(users[i].wallet)
				.fundAccount(BigNumber.from(users[i].index));
		}
	}

	it("Should work", async function () {
		const blsSignerFactory = await BlsSignerFactory.new();
		const users = await setUp(4, blsSignerFactory);

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
					amount: utils.parseUnits("1", 18),
					expiresBy: BigNumber.from(1653523200),
					seqNo: BigNumber.from(1),
				};
				updates.push(getUpdate(users[0], u, r));
			}
		});
		let calldata = preparePostCalldata(updates);
		calldata = new Uint8Array([
			...utils.arrayify(stateBLS.interface.getSighash("post()")),
			...calldata,
		]);
		let d = await stateBLS.provider.call(
			prepareTransaction(stateBLS, calldata)
		);
		console.log(d, " d is here!");

		// // let d = stateBLS.interface.encodeFunctionData("post", [calldata]);
	});
});
