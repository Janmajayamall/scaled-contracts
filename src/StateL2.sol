import "./test/Console.sol";

// Optimizes heavily to reduce calldata
contract StateL2 {
    mapping(uint64 => address) public addresses;
    mapping(address => uint64) public addressesReverse;
    
    uint64 public count;

    struct PartialReceipt {
        uint64 bIndex;
        uint128 amount;
        uint32 expiresBy;
        bytes aSignature;
        bytes bSignature;
    }

    function register(address user) public {
        if (addressesReverse[user] != 0) {
            // already registered
            revert();
        }

        uint64 c = count;
        c += 1;
        addresses[c] = user;
        addressesReverse[user] = c;
        count = c;
    }

    function getUpdateAtIndex(uint256 i) internal view returns (PartialReceipt memory r){
        // 8 bytes
        uint64 bIndex;
        // 16 bytes
        uint128 amount;
        // 4 bytes
        uint32 expiresBy;
        // 65 bytes
        bytes memory aSignature = new bytes(65);
        // 65 bytes
        bytes memory bSignature = new bytes(65);

        uint256 offset = 4 + (i * 158);
        assembly {
            bIndex := shr(192, calldataload(offset))

            offset := add(offset, 8)
            amount := shr(128, calldataload(offset))

            // expiresBy 
            offset := add(offset, 16)
            expiresBy := shr(224, calldataload(offset))

            // aSignature
            offset := add(offset, 4)
            mstore(add(aSignature,32), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(aSignature,64), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(aSignature,96), calldataload(offset))

            // bSignature
            offset := add(offset, 1)
            mstore(add(bSignature,32), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(bSignature,64), calldataload(offset))
            offset := add(offset, 32)
            mstore(add(bSignature,96), calldataload(offset))

        }

        r = PartialReceipt({
            bIndex: bIndex,
            amount: amount,
            expiresBy: expiresBy,
            aSignature: aSignature,
            bSignature: bSignature
        });
    }
    
    function post() external {
        PartialReceipt memory r = getUpdateAtIndex(0);
        console.logBytes(r.aSignature);
        console.logBytes(r.bSignature);
    }
}