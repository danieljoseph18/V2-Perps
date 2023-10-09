# PRINT3R V2

State Update Subgraph 1: NET PNL AND NET OPEN INTEREST FOR ALL MARKETS

- Track the address of each Market contract in the ecosystem
- For each market, call getNetPnL(true), getNetPnL(false) and getNetOpenInterest
- Tally them all up
- Perform safety checks to ensure the values are accurate SUPER IMPORTANT
- Call the VaultUpdater contracts with the final result to update the contract state