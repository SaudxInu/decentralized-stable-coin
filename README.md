# Decentralized Stable Coin (DSC)

## About

This project is meant to be a stablecoin where users can deposit WETH and WBTC in exchange for a token that will be pegged to the USD.

## Details

1. Relative Stability: Anchored or Pegged.
   1. 1 DSC == 1 USD
2. Stability Mechanism (Minting and Burning): Algorithmic. Decentralized.
   1. Chainlink price feed.
   2. Set a function to exchange ETH and BTC for DSC.
   3. Overcollateralized.
3. Collateral: Exogeneous. Crypto.
   1. wETH
   2. wBTC

## Known Bug

A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone. For example, if the price of the collateral plummeted before anyone could be liquidated.
