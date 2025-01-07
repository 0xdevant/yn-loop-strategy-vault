// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

interface IAaveLoopStrategyVault {
    struct LoopParams {
        uint256 numOfLoop;
        uint256 swapAmountOutMin;
        uint160 sqrtPriceLimitX96;
        uint64 slippageBP;
    }

    /// @dev Storage structure for strategy-specific parameters
    struct StrategyStorage {
        bool hasAllocators;
    }

    /// @dev Emitted when the hasAllocator flag is set
    event SetHasAllocator(bool hasAllocator);

    /// @dev Error message returned when numOfLoop is passed as zero when syncDeposit is true
    error LoopVault__ZeroNumOfLoop();
    /// @dev Error message returned when numOfLoop is passed less that needed to withdraw enough assets
    error LoopVault__InsufficientLoops();
    /// @dev Error message returned when the diff between expected and actual amountOut is bigger than the slippageBP tolerance
    error LoopVault__ExceedSlippageBP(uint256 diffOnActualAndExpectedOutWithPrecision);
    error LoopVault__AssetNotActive();

    function depositWithLoop(uint256 assets, address receiver, bytes calldata loopParams)
        external
        returns (uint256 shares);
    function withdrawFromLoop(uint256 assets, address receiver, address owner, bytes calldata loopParams)
        external
        returns (uint256 shares);

    function getExchangeRate() external view returns (uint256);
    function getSuppliedInETH() external view returns (uint256);
    function getBorrowedInETH() external view returns (uint256);
    function getAvailableBorrowInETH() external view returns (uint256);
    function getAssetPrice() external view returns (uint256);
    function getETHPrice() external view returns (uint256);
    function getVaultAccountData()
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
    function getHasAllocator() external view returns (bool hasAllocators);
}

interface IAaveProtocolDataProvider {
    function getUserReserveData(address asset, address user)
        external
        view
        returns (
            uint256 currentATokenBalance,
            uint256 currentStableDebt,
            uint256 currentVariableDebt,
            uint256 principalStableDebt,
            uint256 scaledVariableDebt,
            uint256 stableBorrowRate,
            uint256 liquidityRate,
            uint40 stableRateLastUpdated,
            bool usageAsCollateralEnabled
        );
}

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

interface ISwapRouter02 {
    // there is no deadline in the swap params for SwapRouter02
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams memory params) external returns (uint256 amountOut);

    function wrapETH(uint256 value) external payable;
}
