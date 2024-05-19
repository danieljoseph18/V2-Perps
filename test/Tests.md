# REMAINING TESTS

### Scratch Space

|---------------------------------------------|--------------------|--------------------|-------------------|------------------|
| src/factory/MarketFactory.sol               | 65.31% (64/98)     | 61.60% (77/125)    | 30.00% (9/30)     | 50.00% (12/24)   |
| src/libraries/Borrowing.sol                 | 87.50% (35/40)     | 88.89% (56/63)     | 68.75% (11/16)    | 100.00% (7/7)    |
| src/libraries/Funding.sol                   | 100.00% (42/42)    | 100.00% (59/59)    | 75.00% (3/4)      | 100.00% (8/8)    |
| src/libraries/Gas.sol                       | 62.50% (15/24)     | 60.61% (20/33)     | 43.75% (7/16)     | 80.00% (4/5)     |
| src/libraries/MathUtils.sol                 | 59.68% (37/62)     | 75.32% (58/77)     | 33.33% (5/15)     | 94.12% (16/17)   |
| src/libraries/PriceImpact.sol               | 96.83% (61/63)     | 92.21% (71/77)     | 79.41% (27/34)    | 100.00% (6/6)    |
| src/markets/Market.sol                      | 79.72% (114/143)   | 69.90% (144/206)   | 43.55% (27/62)    | 88.10% (37/42)   |
| src/markets/MarketUtils.sol                 | 86.09% (130/151)   | 83.27% (209/251)   | 65.38% (34/52)    | 92.00% (23/25)   |
| src/markets/Pool.sol                        | 80.95% (34/42)     | 82.76% (48/58)     | 66.67% (20/30)    | 100.00% (7/7)    |
| src/markets/Vault.sol                       | 83.67% (123/147)   | 79.65% (137/172)   | 58.57% (41/70)    | 94.12% (16/17)   |
| src/oracle/Oracle.sol                       | 24.68% (39/158)    | 22.69% (54/238)    | 4.55% (3/66)      | 42.86% (12/28)   |
| src/oracle/PriceFeed.sol                    | 0.00% (0/168)      | 0.00% (0/229)      | 0.00% (0/56)      | 0.00% (0/32)     |
| src/positions/Execution.sol                 | 95.98% (167/174)   | 91.13% (226/248)   | 75.00% (63/84)    | 100.00% (27/27)  |
| src/positions/Position.sol                  | 73.74% (73/99)     | 66.90% (95/142)    | 57.14% (24/42)    | 86.96% (20/23)   |
| src/positions/TradeEngine.sol               | 92.54% (124/134)   | 87.90% (138/157)   | 59.52% (25/42)    | 89.47% (17/19)   |
| src/positions/TradeStorage.sol              | 76.06% (54/71)     | 67.02% (63/94)     | 53.85% (14/26)    | 55.56% (15/27)   |
| src/referrals/Referral.sol                  | 100.00% (6/6)      | 100.00% (9/9)      | 100.00% (0/0)     | 100.00% (1/1)    |
| src/referrals/ReferralStorage.sol           | 67.92% (36/53)     | 60.87% (42/69)     | 50.00% (12/24)    | 64.71% (11/17)   |
| src/rewards/FeeDistributor.sol              | 87.50% (35/40)     | 87.50% (49/56)     | 87.50% (14/16)    | 83.33% (5/6)     |
| src/rewards/GlobalRewardTracker.sol         | 78.86% (138/175)   | 71.81% (163/227)   | 64.10% (50/78)    | 76.32% (29/38)   |
| src/router/PositionManager.sol              | 60.47% (52/86)     | 59.46% (66/111)    | 46.67% (14/30)    | 46.67% (7/15)    |
| src/router/Router.sol                       | 59.26% (80/135)    | 56.10% (115/205)   | 42.11% (32/76)    | 50.00% (8/16)    |
| src/types/MarketId.sol                      | 0.00% (0/1)        | 0.00% (0/1)        | 100.00% (0/0)     | 100.00% (1/1)    |
| test/mocks/MockPriceFeed.sol                | 48.65% (72/148)    | 48.45% (94/194)    | 23.81% (10/42)    | 45.45% (15/33)   |
| Total                                       | 67.74% (1531/2260) | 57.56% (2340/4065) | 38.99% (464/1190) | 56.11% (381/679) |


### Notes

- Need to update the code license to BUSL1.1

### Common Exploit Tests

- Reentrancy Tests
- Blacklisted Addresses on USDC
- Unexecutable Orders
- Referral Spoofing
- Accounting Exploits
- Rounding Errors (Math)
- Oracle Exploits (manipulation)
- Front-running attacks -> with new open keeper role?
- Vault errors - review ERC 4337 Vaults
