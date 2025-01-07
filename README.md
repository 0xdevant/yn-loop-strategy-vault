## AAVE v3 Looping strategy YN Vault

## Getting Started

```
$ git clone https://github.com/0xdevant/yn-loop-strategy-vault
$ cd yn-loop-strategy-vault
$ forge install
```

## Project Structure

```
├── src
│   ├── AaveLoopStrategyVault.sol
│   └── interfaces
│       └── IAaveVaultInterfaces.sol
└── test
    ├── AaveLoopStrategyVault.t.sol
    ├── BaseSetup.t.sol
    ├── VaultSetup.t.sol
    └── helpers
        └── Constants.sol
```

## Architecture decisions

- `BaseVault.sol` from YieldNest is used in this strategy vault to ensure this vault has the best compatibility when integrating with YN
- Having roles like `Allocator` and `AllocatorManager` to simulate the setup environment in production
- E-mode is activiated for the vault in order to get maximum LTV
- Reference `KernelStrategy.sol` to have StrategyStorage like hasAllocator to simulate scenarios where we may want to bypass the allocator role check
- I found flashloan much more efficient and gas-effective than iteratively looping but due to time limit I am sorry that I cannot implement with such approach

### Security Assumpations

- Collateral risk: we assume wstETH is safe from depeg risk, counterparty risk and smart contract risk
- Access control risk: we assume all the permissioned roles are safe from private key or phishing attack so they won't deploy malicious configs or strategies
- Smart contract risk: we assume AAVE v3 contracts and Uniswap router contracts are safe to use
- Oracle risk: we assume the Price Oracle is reporting correct and accurate data without getting manipulated
- Volatile fee risk: we assume the related lending/borrowing fee is stable and won't suddenly change without going through a standard governance process
- Swap Params: ideally the `amountOutMin` and `sqrtPriceLimitX96` passed to `swap` should be calculated by quoting from Quoter contract off-chain or from a price oracle on-chain to protect from price manipulation and price impact

## Usage

### Test

```shell
$ forge test -vvv
```

## Suggestions

For `BaseVault.sol` there are other implementation approaches or optimizations that I think could be discussed:

1. Use UUPS proxy pattern instead of proxy admin to save deployment cost, with permissioned upgrader role set from contract like Access Control Manager
2. Use modifier to replace duplicate codes (e.g. if(paused()) => return 0)
3. Could save unnessary SLOAD on `_subTotalAssets()`
4. Could consider use a constant instead of 18 as a magic number for L-592(... && decimals\_ != 18)
