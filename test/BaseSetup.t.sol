// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";

import {DEFAULT_BALANCE} from "./helpers/Constants.sol";

contract BaseSetup is Test {
    address[] public users;

    function setUp() public virtual {
        setUpUsers();
    }

    function setUpUsers() public {
        string[] memory names = new string[](5);
        names[0] = "admin";
        names[1] = "alice";
        names[2] = "bob";
        names[3] = "charlie";

        for (uint256 i = 0; i < names.length; i++) {
            users.push(makeAddr(names[i]));
            deal(users[i], DEFAULT_BALANCE);
        }
    }
}
