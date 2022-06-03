// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {BLS} from "./../../contracts/libraries/BLS.sol";
import {Vm} from "./Vm.sol";

library BLSUtils {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function blsSign(uint256 secretKey, bytes32 domain, bytes memory message) internal returns (uint256[2] memory) {
        uint256[2] memory point = BLS.hashToPoint(domain, message);
        uint256[3] memory input;
        input[0] = point[0];
        input[1] = point[1];
        input[2] = secretKey;
        // sign the msg
        assembly {
            let success := staticcall(gas(), 7, input, 96, point, 64)
            if iszero(success) {
                invalid()
            }
        }
        return point;
    }

    function genSecret(string memory length) internal returns (uint256) {
        string[] memory scriptArgs = new string[](5);
        scriptArgs[0] =  "node";
        scriptArgs[1] = "./test/hh/scripts/solidity-test.js";
        scriptArgs[2] = "random";
        scriptArgs[3] = "--bytes";
        scriptArgs[4] = length;
        bytes memory res = vm.ffi(scriptArgs); 
        return uint256(bytes32(res));
    }
}