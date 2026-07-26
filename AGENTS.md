# Gauge Validator

This Foundry project implements the factory-first, current-state Curve gauge
validator defined by `ARCHITECTURE.md`.

## Production shape

- `src/GaugeValidator.sol` is the stable core. It owns gauge routes, exact
  factory bindings, exactly-one-match resolution, and the pointer to one active
  proposal-analysis module. It interprets neither validation IDs nor proposal
  syntax.
- `src/GaugeValidationModuleV1.sol` groups the four initial current-state
  gauge-validation methods.
- `src/ProposalAnalysisModuleV1.sol` owns strict recognized gauge-addition
  parsing and calls the core's public `validateGauge` entrypoint.
- `src/MainnetGaugeConfiguration.sol` is deployment input, not a registry or
  core validation logic.
- `script/DeployGaugeValidator.s.sol` creates both immutable modules and then
  the fully configured core, with Curve governance as owner from construction.

The owner adds a gauge module by adding routes that reference it. Removal
requires rebinding or revoking every factory first, then removing its routes.
The owner may replace the active proposal analyzer or set it to zero to disable
proposal analysis.

## Required invariants

- `validateGauge(address)` receives only a gauge address.
- Zero exact matches are invalid.
- One exact match is valid.
- Multiple exact matches are invalid.
- A factory is accepted only through the exact route to which it is bound.
- The core continues after the first match and never treats a successful
  prefix as final.
- Gauge-module failures, malformed returns, low gas, and return-data bombs
  cannot produce true.
- The core has no validation-method enum and never interprets `validationId`.
- Governance-selected modules are trusted policy components.
- The proposal analyzer recognizes only canonical direct or ownership-Agent-
  wrapped `GaugeController.add_gauge` actions and ignores structurally valid
  unrelated calls.
- Rejected callscripts expose no partial gauge additions.
- Proposal results report current state only. They do not model
  proposal-created state.
- A disabled or reverting proposal analyzer returns `UNAVAILABLE`.
- LlamaLend v2 vault gauges use the configured, governance-owned gauge
  factory's `is_valid_gauge` attestation.
- Manually deployed LlamaLend liquidity-mining callbacks are out of scope.
- GaugeController membership and self-reported factories are insufficient.
- EOA-deployed legacy gauges without configured factory provenance are out of
  scope.

## Reproducible mainnet verification

Use `http://wavey:8545` unless the user supplies another Ethereum RPC.

Pinned state:

- chain ID: `1`
- block: `25,619,622`
- hash:
  `0x3995ff2d82e9b602f8c36a4b408e13bcda78dfdebd79e3ff87c89044569ec059`
- timestamp: `2026-07-26T21:20:47Z`

Reference generators must remain independent implementations. They may use
direct RPC reads, but must not derive expected gauge booleans by calling the
Solidity validator under test.

```sh
RPC_URL=http://wavey:8545 FORK_BLOCK=25619622 \
  node script/generate-gauge-manifest.mjs

RPC_URL=http://wavey:8545 FORK_BLOCK=25619622 \
  node script/generate-proposal-manifest.mjs
```

Historical manifests are observational regression evidence. Do not add policy
exceptions merely to make every legacy gauge or proposal pass.

## Verification commands

```sh
forge fmt --check
forge build --sizes
forge lint
RPC_URL=http://wavey:8545 forge test -vv
```

Use pinned forks for representative mainnet behavior and mocks for route
bookkeeping, adversarial protocol dependencies, malformed callscripts, and
method-level negative cases.

Before deployment, simulate all three creation transactions on the pinned fork
and read back every immutable, route, and binding. Deployment, ownership,
module replacement, and every later route mutation remain Curve governance
actions.
