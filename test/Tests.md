# REMAINING TESTS

### Scratch Space

Where is collateral out edited in decrease positions?
- decreaseState.positionFee calculation -> issue here?
    - afterwards = collateral delta - position fee
- calculate borrow fees -> issue here?
    - afterwards = collateral delta - position fee - borrow fee
- process funding fees
- Size and collateral increase / decreases don't need to be proportional
- Need to validate amount of tokens in * price == size delta in usd


### Notes

- Fee discounts aren't being correctly accounted for
If ref code is used -> user gets a discount on their fee. From the total percentage, it's
split in 2, so 50% goes to affiliate as fee reduction, 50% goes to referrer.
totalFee -> fee - (discountPercentage / 2)

- For transfer ins, move transfer to beginning of function

- A lot of gas can be saved by using less structs -> prune where possible

- There is an issue of inconsistent prices being used in some places (specifically testAdl test case).
When index token == collateral token, the prices used should also be the same but they are not.

### Additions Required

- Handle case for Insolvent Liquidations
- Need to make it clear what variables should never change, and which are mutable.
If each function has it's own state, need to validate each state change for that
function.
- Disable trading for commodoties etc. natively on the market instead of through the Keepers
- Mutation Tests
- Invariant Tests
- More Fuzz Tests
- Formal Verification

### Functionality Tests

- Test ADLs
- Test Gas Refunds
- Test Price Impact calculations more extensively -> especially less liquid markets

### Common Exploit Tests

- Reentrancy Tests
- Unexecutable Orders
- Referral Spoofing
- Accounting Exploits
- Rounding Errors (Math)
- Oracle Exploits (manipulation)
- Front-running attacks
