import { expect } from "chai";
import {
	aggregate,
	BlsSignerFactory,
	BlsSignerInterface,
} from "@thehubbleproject/bls/dist/signer";
import { BigNumber, utils } from "ethers";
import { solG1, solG2, aggregateRaw } from "@thehubbleproject/bls/dist/mcl";
import { getContractFactory } from "@nomiclabs/hardhat-ethers/types";

describe("Tesst1", function () {
	let a: BlsSignerInterface;
	let aIndex = BigNumber.from(1);
	// indexes are of other users are `index` + 1 + `aIndex`
	let users: Array<BlsSignerInterface>;

	const domain = utils.arrayify(121);

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

	async function setUp(count, factory: BlsSignerFactory) {
		a = factory.getSigner(domain);
		for (let i = 0; i < count; i++) {
			users.push(factory.getSigner(domain));
		}
	}

	function indexOfUser(i: Number) {
		return BigNumber.from(i).add(BigNumber.from(1)).add(aIndex);
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

	function prepPostCalldata(updates: Array<Update>): Uint8Array {
		// aggregate signatures
		let sigs: solG1[];
		updates.map((u) => {
			sigs.push(u.aSignature);
			sigs.push(u.bSignature);
		});
		let aggSig = aggregate(sigs);

		// for every update
		let updatesData;

		let calldata = new Uint8Array([
			...utils.arrayify(utils.solidityPack(["uint64"], [aIndex])),
			...utils.arrayify(utils.solidityPack(["uint16"], [updates.length])),
			...utils.arrayify(
				utils.solidityPack(
					["uint256", "uint256"],
					[aggSig[0], aggSig[1]]
				)
			),
		]);

		let preLength = calldata.length;
		updates.forEach((u, index) => {
			let v = utils.arrayify(
				utils.solidityPack(
					["uint64", "uint128"],
					[u.receipt.bIndex, u.receipt.amount]
				)
			);
			calldata.set(v, preLength + index * 24);
		});

		return calldata;
	}

	it("Should work", async function () {
		const blsSignerFactory = await BlsSignerFactory.new();
		await setUp(4, blsSignerFactory);

		const StateBLS = getContractFactory("StateBLS");
	});
});
