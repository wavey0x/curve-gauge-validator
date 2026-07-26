# Curve Gauge Validator

A fail-closed Ethereum validator for modern Curve gauges, with best-effort
current-state analysis of recognized Curve DAO gauge additions.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the standalone design and
[`REFINEMENT_PLAN.md`](REFINEMENT_PLAN.md) for the implementation checklist.

## Public interface

```solidity
function validateGauge(address gauge) external view returns (bool);

function analyzeProposalGaugeAdditions(uint256 proposalId)
    external
    view
    returns (ProposalGaugeAnalysis memory);
```

`validateGauge` needs only the candidate gauge address. The core passes every
active validation ID to the current gauge-policy module and accepts the gauge
only when exactly one ID returns a factory bound to that exact ID:

```text
zero matches      -> false
one match         -> true
multiple matches  -> false
```

Proposal analysis reports recognized `GaugeController.add_gauge` actions in
proposal order and evaluates each gauge against current onchain state. It does
not approve the complete proposal, review unrelated actions, or predict state
that the proposal would create.

## Production contracts

- `GaugeValidator`: stable core, active validation IDs, exact factory bindings,
  exactly-one-match resolution, replaceable policy pointers, and public
  entrypoints.
- `GaugeValidationModuleV1`: the combined `DIRECT_LP`,
  `DIRECT_OR_POOL_LP`, `VAULT`, and `FACTORY_IS_VALID_GAUGE` current-state
  policies.
- `ProposalAnalysisModuleV1`: strict extraction of recognized direct and
  ownership-Agent-wrapped gauge additions, with current-state boolean results.

Curve governance can idempotently enable or disable validation IDs, rebind or
disable factories, and replace or disable either policy module. Factory
bindings persist while an ID is inactive and become effective again if the ID
is re-enabled. Modules are trusted policy components. There is no proxy,
`delegatecall`, core validation enum, public detailed resolver, or
caller-supplied factory hint.

## Scope

The supported universe is modern gauges deployed through configured Curve
factories and authenticated by reciprocal current onchain relationships.
Ancient gauges deployed directly by EOAs are out of scope and may return
false.

LlamaLend v2 markets do not require gauges to operate. The observed v2 path is
a conventional factory-deployed gauge over a lender vault, authenticated by
`factory.is_valid_gauge(gauge)`. That generic factory attestation proves gauge
provenance, not that the LP token belongs to a particular lending market.
Manually deployed liquidity-mining callbacks are out of scope. Any conclusion
depending on proposal-created state belongs in pinned fork simulation followed
by `validateGauge` against post-execution state.

## Reproducible verification

Pinned Ethereum state:

- RPC: `http://wavey:8545`
- chain ID: `1`
- block: `25,619,622`
- hash:
  `0x3995ff2d82e9b602f8c36a4b408e13bcda78dfdebd79e3ff87c89044569ec059`
- timestamp: `2026-07-26T21:20:47Z`

Run:

```sh
forge fmt --check
forge build --sizes
forge lint
RPC_URL=http://wavey:8545 forge test -vv
```

`test/data/gauge-manifest.json` and `test/data/proposal-manifest.json` are
historical research and regression artifacts, not exhaustive correctness
requirements.

Regenerate independent current-state reference data with:

```sh
RPC_URL=http://wavey:8545 FORK_BLOCK=25619622 \
  node script/generate-gauge-manifest.mjs

RPC_URL=http://wavey:8545 FORK_BLOCK=25619622 \
  node script/generate-proposal-manifest.mjs
```

Simulate the three contract-creation transactions:

```sh
forge script script/DeployGaugeValidator.s.sol:DeployGaugeValidator \
  --rpc-url http://wavey:8545 \
  --fork-block-number 25619622 \
  -vvvv
```

The `GaugeValidator` constructor installs the gauge-policy module, proposal
analyzer, active validation IDs, and exact factory bindings, then assigns Curve
governance as owner. Duplicate constructor IDs are harmless and duplicate
factory entries use the final entry. No script autonomously deploys, signs, or
changes protocol state.
