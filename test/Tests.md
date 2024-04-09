# REMAINING TESTS

### Scratch Space

- Size and collateral increase / decreases don't need to be proportional
- Need to validate amount of tokens in * price == size delta in usd


### Notes

- A lot of gas can be saved by using less structs -> prune where possible

- There is an issue of inconsistent prices being used in some places (specifically testAdl test case).
When index token == collateral token, the prices used should also be the same but they are not.

- Need to update the code license to a suitable one. GPL? GNU?

### Additions Required

- Handle case for Insolvent Liquidations
- Need to make it clear what variables should never change, and which are mutable.
- Can use Chainlink Functions to enable anyone to run a keeper/liquidator -> once supported on Base
- Mutation Tests
- Invariant Tests
- More Fuzz Tests
- Formal Verification
- Can we create a trailing stop loss system onchain?
- Make library functions internal where possible

### Functionality Tests

- Test ADLs
- Test Gas Refunds
- Test Price Impact calculations more extensively -> especially less liquid markets
- There's probably an underlying issue with market allocations.
    e.g what if OI already exists above the limit and the alloc change
    what if alloc is set to 0? Should we revert this case? -> Should make this only possible on removal

### Common Exploit Tests

- Reentrancy Tests
- Blacklisted Addresses on USDC
- Unexecutable Orders
- Referral Spoofing
- Accounting Exploits
- Rounding Errors (Math)
- Oracle Exploits (manipulation)
- Front-running attacks
- Vault errors - review ERC 4337 Vaults
