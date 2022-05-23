import { expect, use } from "chai";
import {
	aggregate,
	BlsSignerFactory,
	BlsSignerInterface,
} from "@thehubbleproject/bls/dist/signer";
import { BigNumber, utils } from "ethers";
import { solG1, solG2, aggregateRaw } from "@thehubbleproject/bls/dist/mcl";
import { getContractFactory } from "@nomiclabs/hardhat-ethers/types";

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

	function setUp(
		count: Number,
		factory: BlsSignerFactory
	): Array<BlsSignerInterface> {
		const domain = utils.arrayify(121);
		let userSigners: Array<BlsSignerInterface> = [];
		for (let i = 0; i < count; i++) {
			userSigners.push(factory.getSigner(domain));
		}
		return userSigners;
	}

	function receiptHex(r: Receipt): string {
		return utils.solidityPack(
			["uint64", "uint64", "uint128", "uint32", "uint16"],
			[r.aIndex, r.bIndex, r.amount, r.expiresBy, r.seqNo]
		);
	}

	function getUpdate(
		a: BlsSignerInterface,
		b: BlsSignerInterface,
		r: Receipt
	): Update {
		let rHex = receiptHex(r);
		return {
			receipt: r,
			aSignature: a.sign(rHex),
			bSignature: b.sign(rHex),
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

	it("Should work", async function () {
		const blsSignerFactory = await BlsSignerFactory.new();
		const users = await setUp(4, blsSignerFactory);

		let updates: Update[] = [];
		users.forEach((u, index) => {
			// user at index 0 is `a`
			if (index != 0) {
				let r: Receipt = {
					aIndex: BigNumber.from(1),
					bIndex: BigNumber.from(1 + index),
					amount: utils.parseUnits("1", 18),
					expiresBy: BigNumber.from(10),
					seqNo: BigNumber.from(1),
				};
				updates.push(getUpdate(users[0], u, r));
			}
		});

		let calldata = preparePostCalldata(updates);
		console.log(calldata);

		// const StateBLS = getContractFactory("StateBLS");
	});
});
