# Show of Hands — contracts

**One Agent ID, one voice**, on BNB Smart Chain. Every action that counts people goes through a single check of the [Agent ID registry](https://bscscan.com/address/0x60b9262456de011f7d15a54cdd8c48baaa8b022f), which issues one soulbound name per Binance account.

| Contract | What it does | Holds money? |
|---|---|---|
| `src/lib/OneVoice.sol` | The one-voice check: `balanceOf > 0`, then `handleOf(caller)`, then `ownerOfHandle(name) == caller`. The voice is `keccak256(name)`, which is the registry's own token id. Each read has a gas ceiling. | – |
| `src/Polls.sol` | Free polls: one vote per Agent ID per poll; 2–8 options; one open poll per Agent ID | Never (no payable function) |
| `src/FundingRounds.sol` | Quadratic funding in native BNB: `weight = (Σ√paid)² − Σpaid`; matching needs ≥ 5 backers; a cap per project, with what the cap frees passed on to other projects; anyone can finalise 24 hours after the end | Yes, until claim, refund or withdraw |
| `src/Attestor.sol` | Writes "backed by N Agent IDs" into the [ERC-8004 Reputation Registry](https://bscscan.com/address/0x8004BAa17C55a88189AE136b182e5fdA19dE9b63) after a round settles | Never |

## Permissions (full disclosure)

- **No owner, no admin, no upgrade path, no pause, no fee.**
- **Money comes in through three functions only:** `createRound`, `topUpPool` and `back`.
- **Money goes out through three functions only:**
  - `claim`: to the project's own wallet;
  - `refund`: to the backer's own wallet;
  - `withdrawPool`: to the pool funder's own wallet.
- **Exits never read the Agent ID registry,** so a registry fault can't lock funds.
- **Round steward** (whoever opened the round), before it's finalised:
  - Can: approve projects; delist a project, which refunds its backers and publishes the reason on-chain; cancel the round, which refunds everyone.
  - Can't: take any money, or change dates, limits or the cap.
- **Attestor** relies on the ERC-8004 registries, which a third party runs and can upgrade. That's why it's kept apart from the money.

## Tests

```bash
forge test                                                   # unit, fuzz and invariant tests (mock registry)
BSC_RPC_URL=https://bsc-rpc.publicnode.com forge test -vv    # adds fork tests on live BSC: real holders, real ERC-8004
```

The tests cover:

- **Polls:** one vote per Agent ID; a borrowed name is rejected; registry faults fail cleanly.
- **Funding:** the crowd-vs-whale example; the 5-backer minimum; the cap and passing on what it frees; leftover pool returned to funders.
- **Refunds:** delisting, cancelling, and payouts still working while the registry is down.
- **Limits:** the steward's powers; one wallet that refuses BNB can't block anyone else's payout.
- **Gas at maximum size:** finalising 40 projects costs about 1.4M gas.
- **Invariants:** the contract never owes more than it holds; matching never exceeds the pool.

Gas measured on live BSC: a vote costs about 121k and a first backing about 190k.

## Deploy

```bash
forge script script/Deploy.s.sol --rpc-url bsc --broadcast --verify   # choose the signer at run time, e.g. --ledger
```
