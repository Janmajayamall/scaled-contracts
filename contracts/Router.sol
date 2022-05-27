// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IERC20.sol";
import "./libraries/Transfers.sol";
import "./StateBLS.sol";

contract Router {

    using Transfers for IERC20;

    address stateBls;

    // function fundAccount(uint64 toIndex, uint128 amount) external {
    //     address _stateBls = stateBls;
    //     if (_stateBls == address(0)){
    //         revert();
    //     }

    //     // transfer amount
    //     address token = StateBLS(_stateBls).token();
    //     IERC20(token).safeTransferFrom(msg.sender, _stateBls, uint256(amount));

    //     StateBLS(_stateBls).fundAccount(toIndex);
    // }

    // function depositSecurity(uint64 toIndex, uint128 amount) external {
    //     address _stateBls = stateBls;
    //     if (_stateBls == address(0)){
    //         revert();
    //     }

    //     // transfer amount
    //     address token = StateBLS(_stateBls).token();
    //     IERC20(token).safeTransferFrom(msg.sender, _stateBls, uint256(amount));

        
    //     StateBLS(_stateBls).depositSecurity(toIndex);
    // }
}