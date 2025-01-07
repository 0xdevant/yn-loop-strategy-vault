// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IPool} from "@aave-v3-origin/interfaces/IPool.sol";
import {IERC20, SafeERC20, Math} from "@yieldnest-vault/Common.sol";
import {Vault} from "@yieldnest-vault/Vault.sol";

import {
    IAaveLoopStrategyVault,
    IAaveProtocolDataProvider,
    IAaveOracle,
    ISwapRouter02
} from "./interfaces/IAaveVaultInterfaces.sol";

contract AaveLoopStrategyVault is Vault, IAaveLoopStrategyVault {
    /// @dev Role for allocator permissions
    bytes32 public constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    /// @dev Role for allocator manager permissions
    bytes32 public constant ALLOCATOR_MANAGER_ROLE = keccak256("ALLOCATOR_MANAGER_ROLE");

    IERC20 private constant _MAINNET_WETH_BORROW = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    IPool private constant _MAINNET_AAVE_V3_POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAaveProtocolDataProvider private constant _MAINNET_AAVE_V3_PROTOCOL_DATA_PROVIDER =
        IAaveProtocolDataProvider(0x41393e5e337606dc3821075Af65AeE84D7688CBD);
    ISwapRouter02 private constant _MAINNET_UNI_SWAP_ROUTER_02 =
        ISwapRouter02(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);

    /// @dev `interestRateMode` should always be passed a value of 2
    uint256 private constant _VARIABLE_RATE_MODE = 2;
    uint256 private constant _BASE_PRECISION = 1e18;
    uint256 private constant _BASIS_POINTS = 10_000;
    uint24 private constant _DEFAULT_POOL_FEE = 100; // 0.01%

    modifier onlyAllocator() {
        require(
            _getStrategyStorage().hasAllocators && hasRole(ALLOCATOR_ROLE, msg.sender),
            AccessControlUnauthorizedAccount(msg.sender, ALLOCATOR_ROLE)
        );
        _;
    }

    modifier onlyNotPaused() {
        require(!paused(), Paused());
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    function _initialize(
        address admin,
        string memory name,
        string memory symbol,
        uint8 decimals_,
        uint64 baseWithdrawalFee_,
        bool countNativeAsset_,
        bool alwaysComputeTotalAssets_
    ) internal virtual override {
        super._initialize(
            admin, name, symbol, decimals_, baseWithdrawalFee_, countNativeAsset_, alwaysComputeTotalAssets_
        );
        _grantRole(ALLOCATOR_ROLE, admin);
        _grantRole(ALLOCATOR_MANAGER_ROLE, admin);
        StrategyStorage storage strategyStorage = _getStrategyStorage();
        strategyStorage.hasAllocators = true;
    }

    /*//////////////////////////////////////////////////////////////
                               EXTERNALS
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Deposits a given amount of assets with loop strategy and assigns the equivalent amount of shares to the receiver.
     * @param assets The amount of assets to deposit.
     * @param receiver The address of the receiver.
     * @param loopParams A encoded calldata consists of LoopParams.
     *                   numOfLoop should be calculated beforehand to avoid unnecessary excessed loops.
     * @return uint256 The equivalent amount of shares.
     */
    function depositWithLoop(uint256 assets, address receiver, bytes calldata loopParams)
        external
        virtual
        nonReentrant
        onlyAllocator
        onlyNotPaused
        returns (uint256)
    {
        address asset_ = asset();
        (uint256 shares, uint256 baseAssets) = _convertToShares(asset_, assets, Math.Rounding.Floor);
        super._deposit(asset_, _msgSender(), receiver, assets, shares, baseAssets);

        _depositWithLoop(asset_, assets, loopParams);
        return shares;
    }

    /**
     * @notice Withdraws a given amount of assets and burns the equivalent amount of shares from the owner.
     * @param assets The amount of assets to withdraw.
     * @param receiver The address of the receiver.
     * @param owner The address of the owner.
     * @param loopParams A encoded calldata consists of LoopParams.
     *                   numOfLoop should be calculated beforehand to get enough assets to withdraw.
     * @return shares The equivalent amount of shares.
     */
    function withdrawFromLoop(uint256 assets, address receiver, address owner, bytes calldata loopParams)
        external
        virtual
        nonReentrant
        onlyAllocator
        onlyNotPaused
        returns (uint256 shares)
    {
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ExceededMaxWithdraw(owner, assets, maxAssets);
        }
        shares = previewWithdraw(assets);

        _withdrawFromLoop(_msgSender(), receiver, owner, assets, shares, loopParams);
    }

    /*//////////////////////////////////////////////////////////////
                                 ADMIN
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Sets whether the strategy has allocators.
     * @param hasAllocators The new value for the hasAllocator flag.
     */
    function setHasAllocator(bool hasAllocators) external onlyRole(ALLOCATOR_MANAGER_ROLE) {
        StrategyStorage storage strategyStorage = _getStrategyStorage();
        strategyStorage.hasAllocators = hasAllocators;

        emit SetHasAllocator(hasAllocators);
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/
    function _depositWithLoop(address asset_, uint256 totalAmount, bytes calldata loopParams) internal {
        LoopParams memory params = abi.decode(loopParams, (LoopParams));
        require(params.numOfLoop != 0, LoopVault__ZeroNumOfLoop());

        SafeERC20.safeIncreaseAllowance(IERC20(asset_), address(_MAINNET_AAVE_V3_POOL), totalAmount * params.numOfLoop);
        /**
         * 1. Supply the wstETH to the Aave v3 pool
         * 2. Borrow WETH from the Aave v3 pool
         * 3. Swap the borrowed WETH for wstETH
         * 4. Repeat
         */
        for (uint256 i; i < params.numOfLoop; i++) {
            uint256 remainAmount =
                _loop(asset_, totalAmount, params.swapAmountOutMin, params.sqrtPriceLimitX96, params.slippageBP);
            totalAmount = remainAmount;
        }
        // reset the approval for unused assets after looping
        SafeERC20.forceApprove(IERC20(asset_), address(_MAINNET_AAVE_V3_POOL), 0);
    }

    function _loop(
        address asset_,
        uint256 amount,
        uint256 swapAmountOutMin,
        uint160 sqrtPriceLimitX96,
        uint64 slippageBP
    ) internal returns (uint256 remainAmount) {
        _MAINNET_AAVE_V3_POOL.supply(asset_, amount, address(this), 0);
        uint256 borrowingETH = getAvailableBorrowInETH();
        address wethAddress = address(_MAINNET_WETH_BORROW);
        _MAINNET_AAVE_V3_POOL.borrow(wethAddress, borrowingETH, _VARIABLE_RATE_MODE, 0, address(this));
        remainAmount = _swap(wethAddress, asset_, borrowingETH, swapAmountOutMin, sqrtPriceLimitX96, slippageBP);
    }

    function _withdrawFromLoop(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares,
        bytes calldata loopParams
    ) internal virtual {
        _subTotalAssets(assets);
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // NOTE: burn shares before withdrawing the assets
        _burn(owner, shares);

        address asset_ = asset();
        uint256 vaultBalance = IERC20(asset_).balanceOf(address(this));
        if (vaultBalance < assets) {
            uint256 assetsNeeded = assets - vaultBalance;
            // withdraw the unloopAmount directly if there is no debt
            if (getBorrowedInETH() == 0) {
                _MAINNET_AAVE_V3_POOL.withdraw(asset_, assetsNeeded, address(this));
            } else {
                _unwindLoop(asset_, assetsNeeded, loopParams);
            }
        }

        require(IERC20(asset_).balanceOf(address(this)) >= assets, LoopVault__InsufficientLoops());
        SafeERC20.safeTransfer(IERC20(asset_), receiver, assets);

        emit Withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    function _unwindLoop(address asset_, uint256 unloopAmount, bytes calldata loopParams) internal {
        LoopParams memory params = abi.decode(loopParams, (LoopParams));
        require(params.numOfLoop != 0, LoopVault__ZeroNumOfLoop());

        for (uint256 i; i < params.numOfLoop; i++) {
            uint256 withdrawableAssetInWei = _calculateWithdrawableAsset();
            // exit loop early if enough collateral can be withdrawn
            if (withdrawableAssetInWei >= unloopAmount) {
                break;
            }
            _unloop(
                asset_,
                unloopAmount,
                withdrawableAssetInWei,
                params.swapAmountOutMin,
                params.sqrtPriceLimitX96,
                params.slippageBP
            );
        }
        // Withdraw the avaialble asset collateral after unwinding loop
        _MAINNET_AAVE_V3_POOL.withdraw(asset_, _calculateWithdrawableAsset(), address(this));
    }

    function _unloop(
        address asset_,
        uint256 unloopAmount,
        uint256 withdrawableAssetInWei,
        uint256 swapAmountOutMin,
        uint160 sqrtPriceLimitX96,
        uint64 slippageBP
    ) internal {
        /**
         * 1. Withdraw wstETH from the Aave v3 pool
         * 2. Swap the withdrawn wstETH for WETH
         * 3. Repay the debt for WETH
         * 4. Repeat
         */
        uint256 amountWithdrawn = _MAINNET_AAVE_V3_POOL.withdraw(asset_, withdrawableAssetInWei, address(this));
        // only continue swap + repay if amountWithdrawn is not enough for needed unloopAmount
        if (amountWithdrawn < unloopAmount) {
            address wethAddress = address(_MAINNET_WETH_BORROW);
            // // calculate the amount of WETH to repay
            (,, uint256 wethDebtAmount,,,,,,) =
                _MAINNET_AAVE_V3_PROTOCOL_DATA_PROVIDER.getUserReserveData(wethAddress, address(this));
            // convert wstETH amountWithdrawn to ETH-denominated
            uint256 amountWithdrawnInETH = amountWithdrawn * getAssetPrice() / getETHPrice();
            // if wethDebtAmount is less than amountWithdrawnInETH, just swap with wethDebtAmount to avoid unneeded repay
            uint256 swapAmount = wethDebtAmount < amountWithdrawnInETH ? wethDebtAmount : amountWithdrawn;
            uint256 wethAmountOut =
                _swap(asset_, wethAddress, swapAmount, swapAmountOutMin, sqrtPriceLimitX96, slippageBP);
            SafeERC20.safeIncreaseAllowance(_MAINNET_WETH_BORROW, address(_MAINNET_AAVE_V3_POOL), wethAmountOut);
            _MAINNET_AAVE_V3_POOL.repay(wethAddress, wethAmountOut, _VARIABLE_RATE_MODE, address(this));
        }
    }

    function _calculateWithdrawableAsset() internal view returns (uint256 withdrawableAssetInWei) {
        (uint256 totalCollateral, uint256 totalDebt,, uint256 liquidationThreshold,,) = getVaultAccountData();
        // get withdrawable collateral in wei that makes healthFactor >= 1
        withdrawableAssetInWei =
            (totalCollateral * liquidationThreshold / _BASIS_POINTS - totalDebt) * _BASE_PRECISION / getAssetPrice();
    }

    function _swap(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 swapAmountOutMin,
        uint160 sqrtPriceLimitX96,
        uint64 slippageBP
    ) internal returns (uint256 amountOut) {
        SafeERC20.safeIncreaseAllowance(IERC20(assetIn), address(_MAINNET_UNI_SWAP_ROUTER_02), amountIn);
        amountOut = _MAINNET_UNI_SWAP_ROUTER_02.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: assetIn,
                tokenOut: assetOut,
                fee: _DEFAULT_POOL_FEE,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: swapAmountOutMin,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );
        _checkSlippage(amountOut, swapAmountOutMin, slippageBP);
    }

    /// @dev Ideally the amountOutMin should be calculated by quoting from Quoter contract off-chain or from a price oracle on-chain to make this check effective
    function _checkSlippage(uint256 amountOut, uint256 swapAmountOutMin, uint64 slippageBP) private pure {
        if (swapAmountOutMin == 0) return;
        uint256 diffOnActualAndExpectedOutWithPrecision =
            (amountOut - swapAmountOutMin) * _BASE_PRECISION / swapAmountOutMin;
        require(
            diffOnActualAndExpectedOutWithPrecision < (slippageBP * _BASE_PRECISION),
            LoopVault__ExceedSlippageBP(diffOnActualAndExpectedOutWithPrecision)
        );
    }

    /**
     * @notice Retrieves the strategy storage structure.
     * @return $ The strategy storage structure.
     */
    function _getStrategyStorage() internal pure virtual returns (StrategyStorage storage $) {
        assembly {
            // keccak256("yieldnest.storage.strategy")
            $.slot := 0x0ef3e973c65e9ac117f6f10039e07687b1619898ed66fe088b0fab5f5dc83d88
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/
    /// @notice Returns the rate of how much a single strategy asset(ynLoopWstETHa) in the vault is worth of in ETH
    function getExchangeRate() external view returns (uint256) {
        return convertToAssets(1e18) * getAssetPrice() / getETHPrice();
    }

    /// @return Total collateral in ETH in wei
    function getSuppliedInETH() external view returns (uint256) {
        (uint256 totalCollateralInUSD,,,,,) = getVaultAccountData();
        return totalCollateralInUSD * _BASE_PRECISION / getETHPrice();
    }

    /// @return Total debt in ETH in wei
    function getBorrowedInETH() public view returns (uint256) {
        (, uint256 totalDebtInUSD,,,,) = getVaultAccountData();
        return totalDebtInUSD * _BASE_PRECISION / getETHPrice();
    }

    /// @return Available borrow amount in ETH in wei
    function getAvailableBorrowInETH() public view returns (uint256) {
        (,, uint256 availableBorrowsInUSD,,,) = getVaultAccountData();
        return availableBorrowsInUSD * _BASE_PRECISION / getETHPrice();
    }

    /// @return The ASSET price in USD according to Aave PriceOracle
    function getAssetPrice() public view returns (uint256) {
        return IAaveOracle(_MAINNET_AAVE_V3_POOL.ADDRESSES_PROVIDER().getPriceOracle()).getAssetPrice(address(asset()));
    }

    /// @return ETH price in USD according to Aave PriceOracle
    function getETHPrice() public view returns (uint256) {
        return IAaveOracle(_MAINNET_AAVE_V3_POOL.ADDRESSES_PROVIDER().getPriceOracle()).getAssetPrice(
            address(_MAINNET_WETH_BORROW)
        );
    }

    /// @return totalCollateralBase Total Collateral in USD
    /// @return totalDebtBase Total Debt in USD
    /// @return availableBorrowsBase Available Borrows in USD
    /// @return currentLiquidationThreshold Current liquidation Threshold
    /// @return ltv Loan to value
    /// @return healthFactor Current health factor
    function getVaultAccountData()
        public
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        (totalCollateralBase, totalDebtBase, availableBorrowsBase, currentLiquidationThreshold, ltv, healthFactor) =
            _MAINNET_AAVE_V3_POOL.getUserAccountData(address(this));
    }

    /**
     * @notice Returns whether the strategy has allocators.
     * @return hasAllocators True if the strategy has allocators, otherwise false.
     */
    function getHasAllocator() external view returns (bool hasAllocators) {
        return _getStrategyStorage().hasAllocators;
    }

    /**
     * @notice Returns the maximum amount of assets that can be withdrawn by a given owner.
     * @param owner The address of the owner.
     * @return uint256 The maximum amount of assets.
     */
    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        if (paused() || !_getAssetStorage().assets[asset()].active) {
            return 0;
        }

        uint256 ownerShares = balanceOf(owner);
        return previewRedeem(ownerShares);
    }

    /**
     * @notice Returns the maximum amount of shares that can be redeemed by a given owner.
     * @param owner The address of the owner.
     * @return uint256 The maximum amount of shares.
     */
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        if (paused() || !_getAssetStorage().assets[asset()].active) {
            return 0;
        }

        uint256 ownerShares = balanceOf(owner);
        return previewRedeem(ownerShares);
    }
}
