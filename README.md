# modern compiler & exp upgrade of V2 DEX contracts & extras

// liquidityTrackRecord in LPs = stores LP token data the user has provided (rewards/christmas gift/leaderboards for example )

// swapFeeOverride: dao/team/project can customize and make dynamic swap fees for the LP pairing, higher liquidity mining rewards, etc. fee manager should be set to multi-sig/vault or governance contract.

swapFor0: swapping tokens for token0 of the pair. only requires the amount of token0 that the user wants to receive (amount0Out) and the address to receive the tokens. kinda weird lol

swapFor1: swapFor0's twin

