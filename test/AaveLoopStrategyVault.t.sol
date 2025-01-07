// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "@aave-v3-origin/interfaces/IPool.sol";
import {IVault} from "@yieldnest-vault/interface/IVault.sol";

import {VaultSetup} from "./VaultSetup.t.sol";
import {
    MAINNET_WSTETH_ADDR,
    MAINNET_WETH_ADDR,
    MAINNET_AAVE_V3_POOL_ADDR,
    BASIS_POINTS,
    SAFE_BUFFER
} from "./helpers/Constants.sol";

contract AaveLoopStrategyVaultTest is Test, VaultSetup {
    function setUp() public override {
        VaultSetup.setUp();
    }

    function test_depositWithLoop_ExecuteAAVELoopStrategy_OnMainnetFork() public {
        uint256 depositETHAmount = 1 ether;
        uint256 numOfLoop = 3;
        uint256 amountOutMin = 0; // ideally this should be calculated by quoting off-chain or through Oracle
        uint160 sqrtPriceLimitX96 = 0;
        uint64 slippageBP = 100; // 1%

        address allocator = users[0];
        address alice = users[1];
        uint256 depositWstETHAmount = prepareWstETHInVault(alice, allocator, depositETHAmount);

        // Scenario: Alice deposited wstETH, allocator acts like a YN MAX-LRT vault that will allocate the wstETH to the Aave Loop Strategy Vault
        vm.prank(allocator);
        uint256 share = aaveLoopVault.depositWithLoop(
            depositWstETHAmount, allocator, abi.encode(numOfLoop, amountOutMin, sqrtPriceLimitX96, slippageBP)
        );

        assertEq(aaveLoopVault.balanceOf(allocator), share);
        assertEq(IERC20(MAINNET_WETH_ADDR).balanceOf(address(aaveLoopVault)), 0);
        console.log("Total Assets: ", aaveLoopVault.totalAssets());
        console.log("balanceOf wstETH: ", IERC20(MAINNET_WSTETH_ADDR).balanceOf(address(aaveLoopVault)));
        console.log("Supplied: ", aaveLoopVault.getSuppliedInETH());
        console.log("Borrowed: ", aaveLoopVault.getBorrowedInETH());
    }

    function test_withdraw_NormalWithdraw_WhenVaultHasEnoughBalance() public {
        uint256 depositETHAmount = 1 ether;
        uint256 numOfLoop = 3;
        uint256 amountOutMin = 0; // ideally this should be calculated by quoting off-chain or through Oracle
        uint160 sqrtPriceLimitX96 = 0;
        uint64 slippageBP = 100;

        address allocator = users[0];
        address alice = users[1];
        uint256 depositWstETHAmount = prepareWstETHInVault(alice, allocator, depositETHAmount);

        vm.prank(allocator);
        uint256 share = aaveLoopVault.deposit(depositWstETHAmount, allocator);
        assertEq(IERC20(MAINNET_WSTETH_ADDR).balanceOf(address(aaveLoopVault)), depositWstETHAmount);

        uint256 withdrawWstETHAmount = depositWstETHAmount - SAFE_BUFFER;
        vm.prank(allocator);
        uint256 shareBurnt = aaveLoopVault.withdrawFromLoop(
            withdrawWstETHAmount,
            allocator,
            allocator,
            abi.encode(numOfLoop, amountOutMin, sqrtPriceLimitX96, slippageBP)
        );

        assertLt(aaveLoopVault.balanceOf(allocator), share);
        assertEq(IERC20(MAINNET_WETH_ADDR).balanceOf(address(aaveLoopVault)), 0);
        assertEq(IERC20(MAINNET_WSTETH_ADDR).balanceOf(address(aaveLoopVault)), SAFE_BUFFER);
        assertEq(IERC20(MAINNET_WSTETH_ADDR).balanceOf(address(allocator)), withdrawWstETHAmount);
        assertEq(aaveLoopVault.getSuppliedInETH(), 0);
        assertEq(aaveLoopVault.getBorrowedInETH(), 0);
        console.log("Total Assets: ", aaveLoopVault.totalAssets());
        console.log("balanceOf share: ", aaveLoopVault.balanceOf(allocator));
        console.log("balanceOf wstETH: ", IERC20(MAINNET_WSTETH_ADDR).balanceOf(address(aaveLoopVault)));
        console.log("Shares burnt: ", shareBurnt);
    }

    function test_withdrawFromLoop_UnwindLoopFromAAVE_OnMainnetFork() public {
        uint256 depositETHAmount = 0.5 ether;
        uint256 withdrawWstETHAmount = 0.4 ether;
        uint256 numOfLoopForDeposit = 3;
        uint256 numOfLoopForWithdraw = 25;
        uint256 amountOutMin = 0; // ideally this should be calculated by quoting off-chain or through Oracle
        uint160 sqrtPriceLimitX96 = 0;
        uint64 slippageBP = 100;

        address allocator = users[0];
        address alice = users[1];
        uint256 depositWstETHAmount = prepareWstETHInVault(alice, allocator, depositETHAmount);

        console.log("depositWstETHAmount: ", depositWstETHAmount);
        vm.prank(allocator);
        uint256 share = aaveLoopVault.depositWithLoop(
            depositWstETHAmount, allocator, abi.encode(numOfLoopForDeposit, amountOutMin, sqrtPriceLimitX96, slippageBP)
        );
        console.log("after deposit - balanceOf wstETH: ", IERC20(MAINNET_WSTETH_ADDR).balanceOf(address(aaveLoopVault)));

        vm.prank(allocator);
        uint256 shareBurnt = aaveLoopVault.withdrawFromLoop(
            withdrawWstETHAmount,
            allocator,
            allocator,
            abi.encode(numOfLoopForWithdraw, amountOutMin, sqrtPriceLimitX96, slippageBP)
        );

        assertEq(aaveLoopVault.balanceOf(address(aaveLoopVault)), 0);
        assertEq(IERC20(MAINNET_WETH_ADDR).balanceOf(address(aaveLoopVault)), 0);
        assertEq(IERC20(MAINNET_WSTETH_ADDR).balanceOf(allocator), withdrawWstETHAmount);
        console.log("\nTotal Assets: ", aaveLoopVault.totalAssets());
        console.log("Shares minted: ", share);
        console.log("Shares burnt: ", shareBurnt);
        console.log("balanceOf share: ", aaveLoopVault.balanceOf(allocator));
        console.log("balanceOf wstETH: ", IERC20(MAINNET_WSTETH_ADDR).balanceOf(address(aaveLoopVault)));
        console.log("balanceOf WETH: ", IERC20(MAINNET_WETH_ADDR).balanceOf(address(aaveLoopVault)));
        console.log("Supplied: ", aaveLoopVault.getSuppliedInETH());
        console.log("Borrowed: ", aaveLoopVault.getBorrowedInETH());
    }

    function test_withdrawFromLoop_RevertWhenExceedMaxWithdraw() public {
        uint256 depositETHAmount = 0.5 ether;
        uint256 exceedMaxWithdrawWstETHAmount = 2 ether;
        uint256 numOfLoop = 3;
        uint256 amountOutMin = 0;
        uint160 sqrtPriceLimitX96 = 0;
        uint64 slippageBP = 100;

        address allocator = users[0];
        address alice = users[1];
        uint256 depositWstETHAmount = prepareWstETHInVault(alice, allocator, depositETHAmount);

        vm.prank(allocator);
        uint256 share = aaveLoopVault.depositWithLoop(
            depositWstETHAmount, allocator, abi.encode(numOfLoop, amountOutMin, sqrtPriceLimitX96, slippageBP)
        );

        vm.prank(allocator);
        // use `expectPartialRevert` due to depositWstETHAmount will be different for every call on mainnet fork
        vm.expectPartialRevert(IVault.ExceededMaxWithdraw.selector);
        aaveLoopVault.withdrawFromLoop(
            exceedMaxWithdrawWstETHAmount,
            allocator,
            allocator,
            abi.encode(numOfLoop, amountOutMin, sqrtPriceLimitX96, slippageBP)
        );

        assertEq(aaveLoopVault.balanceOf(address(aaveLoopVault)), 0);
        assertEq(IERC20(MAINNET_WETH_ADDR).balanceOf(address(aaveLoopVault)), 0);
        assertEq(IERC20(MAINNET_WSTETH_ADDR).balanceOf(allocator), 0);
        console.log("Total Assets: ", aaveLoopVault.totalAssets());
        console.log("Shares minted: ", share);
        console.log("balanceOf share: ", aaveLoopVault.balanceOf(allocator));
    }

    function test_getExchangeRate_AfterDeposit() public {
        uint256 depositETHAmount = 0.5 ether;
        uint256 numOfLoopForDeposit = 3;
        uint256 amountOutMin = 0;
        uint160 sqrtPriceLimitX96 = 0;
        uint64 slippageBP = 100;

        address allocator = users[0];
        address alice = users[1];
        uint256 depositWstETHAmount = prepareWstETHInVault(alice, allocator, depositETHAmount);

        vm.prank(allocator);
        aaveLoopVault.depositWithLoop(
            depositWstETHAmount, allocator, abi.encode(numOfLoopForDeposit, amountOutMin, sqrtPriceLimitX96, slippageBP)
        );

        // assertEq(aaveLoopVault.getExchangeRate(), 0);
        console.log("exchangeRate: ", aaveLoopVault.getExchangeRate());
    }

    function prepareWstETHInVault(address from, address to, uint256 amount)
        public
        returns (uint256 wstETHBalanceFrom)
    {
        vm.startPrank(from);
        (bool sent,) = payable(MAINNET_WSTETH_ADDR).call{value: amount}("");
        require(sent, "Failed to send Ether");
        wstETHBalanceFrom = IERC20(MAINNET_WSTETH_ADDR).balanceOf(from);
        // console.log("wstETHBalanceFrom: ", wstETHBalanceFrom);
        IERC20(MAINNET_WSTETH_ADDR).transfer(to, wstETHBalanceFrom);
        vm.stopPrank();
    }

    // function calculateFlashLoanPremium(uint256 amount) public view returns (uint256) {
    //     return amount * IPool(MAINNET_AAVE_V3_POOL_ADDR).FLASHLOAN_PREMIUM_TOTAL() / BASIS_POINTS;
    // }
}
