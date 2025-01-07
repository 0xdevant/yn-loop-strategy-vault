// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {console} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "@aave-v3-origin/interfaces/IPool.sol";
import {DataTypes} from "@aave-v3-origin/protocol/libraries/types/DataTypes.sol";
import {IUiPoolDataProviderV3} from "@aave-v3-origin/helpers/interfaces/IUiPoolDataProviderV3.sol";
import {Vault} from "@yieldnest-vault/Vault.sol";
import {Etches} from "@yieldnest-vault-test/mainnet/helpers/Etches.sol";

import {AaveLoopStrategyVault} from "src/AaveLoopStrategyVault.sol";
import {BaseSetup} from "./BaseSetup.t.sol";
import {
    MAINNET_WETH_ADDR,
    MAINNET_WSTETH_ADDR,
    MAINNET_AAVE_V3_ADDRESS_PROVIDER_ADDR,
    MAINNET_AAVE_V3_POOL_ADDR,
    MAINNET_AAVE_V3_UI_POOL_DATA_PROVIDER_ADDR,
    EMODE_CATEGORY_ID
} from "./helpers/Constants.sol";

contract VaultSetup is BaseSetup, Etches {
    IPool public mainnetPool = IPool(MAINNET_AAVE_V3_POOL_ADDR);
    IUiPoolDataProviderV3 public mainnetUiPoolDataProviderV3 =
        IUiPoolDataProviderV3(MAINNET_AAVE_V3_UI_POOL_DATA_PROVIDER_ADDR);

    AaveLoopStrategyVault public aaveLoopVaultImpl;
    AaveLoopStrategyVault public aaveLoopVault;

    struct VaultInitParams {
        address admin;
        string name;
        string symbol;
        uint8 decimals;
        uint64 baseWithdrawalFee;
        bool countNativeAsset;
        bool alwaysComputeTotalAssets;
    }

    function setUp() public virtual override {
        // setup on mainnet fork as some calls are based on the fact that tokens exist on mainnet
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        BaseSetup.setUp();
        deployVaultAndGrantRoles();
        configureVault();
        switchOnEModeForVault();
        labelContracts();
    }

    function deployVaultAndGrantRoles() public {
        aaveLoopVaultImpl = new AaveLoopStrategyVault();
        VaultInitParams memory params = VaultInitParams({
            admin: users[0],
            name: "Yiednest AAVE Loop Strategy wstETH",
            symbol: "ynLoopWstETHa",
            decimals: 18,
            baseWithdrawalFee: 0,
            countNativeAsset: true,
            alwaysComputeTotalAssets: false
        });

        bytes memory initData = abi.encodeCall(
            Vault.initialize,
            (
                params.admin,
                params.name,
                params.symbol,
                params.decimals,
                params.baseWithdrawalFee,
                params.countNativeAsset,
                params.alwaysComputeTotalAssets
            )
        );
        aaveLoopVault = AaveLoopStrategyVault(
            payable(address(new TransparentUpgradeableProxy(address(aaveLoopVaultImpl), users[0], initData)))
        );
    }

    function configureVault() public {
        mockAll();

        address admin = users[0];
        vm.startPrank(admin);
        IERC20(MAINNET_WSTETH_ADDR).approve(address(aaveLoopVault), type(uint256).max);
        aaveLoopVault.grantRole(keccak256("UNPAUSER_ROLE"), admin);
        aaveLoopVault.grantRole(keccak256("PROVIDER_MANAGER_ROLE"), admin);
        aaveLoopVault.grantRole(keccak256("ASSET_MANAGER_ROLE"), admin);
        aaveLoopVault.grantRole(keccak256("BUFFER_MANAGER_ROLE"), admin);

        aaveLoopVault.setProvider(address(123456789));
        aaveLoopVault.setBuffer(address(987654321));
        aaveLoopVault.addAsset(MAINNET_WSTETH_ADDR, true);
        // aaveLoopVault.addAsset(MAINNET_WETH_ADDR, true);

        aaveLoopVault.unpause();
        aaveLoopVault.processAccounting();
        vm.stopPrank();
    }

    /// @dev In order to get maximum LTV, we need to switch on EMode for the vault
    function switchOnEModeForVault() internal {
        vm.prank(address(aaveLoopVault));
        mainnetPool.setUserEMode(EMODE_CATEGORY_ID);
    }

    function labelContracts() internal {
        vm.label({account: address(this), newLabel: "TestContract"});
        vm.label({account: address(aaveLoopVaultImpl), newLabel: "AaveLoopStrategyVaultImpl"});
        vm.label({account: address(aaveLoopVault), newLabel: "AaveLoopStrategyVault/ynLoopWstETHa"});
        vm.label({account: MAINNET_AAVE_V3_POOL_ADDR, newLabel: "Mainnet_AaveV3Pool"});
        vm.label({account: MAINNET_AAVE_V3_UI_POOL_DATA_PROVIDER_ADDR, newLabel: "Mainnet_AaveV3UiPoolDataProvider"});
        vm.label({account: MAINNET_WETH_ADDR, newLabel: "Mainnet_WETH"});
        vm.label({account: MAINNET_WSTETH_ADDR, newLabel: "Mainnet_WstETH"});
    }
}
