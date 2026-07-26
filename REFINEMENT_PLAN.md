# Curve Gauge Validator Implementation Checklist

## Objective

Implement the factory-first architecture in `ARCHITECTURE.md` with the smallest
policy surface that covers current production gauge deployment patterns.

The deployment remains three contracts:

```text
GaugeValidator
GaugeValidationModuleV1
ProposalAnalysisModuleV1
```

## Final scope

Keep:

- `validateGauge(address) -> bool`;
- complete scanning with zero/one/multiple-match semantics;
- opaque `(module, validationId)` routes;
- exact factory-to-route bindings;
- one combined, replaceable gauge-policy module;
- one replaceable proposal-analysis module;
- current-state analysis of recognized `GaugeController.add_gauge` actions;
- strict callscript framing and authenticated ownership-Agent wrappers; and
- pinned-fork simulation for proposal-created state.

Exclude:

- EOA-deployed historical gauges without factory provenance;
- manually deployed LlamaLend liquidity-mining callbacks;
- proposal-local state overlays;
- caller-supplied factory hints;
- a public detailed resolver;
- a core validation enum;
- per-method adapter contracts;
- a generic proposal virtual machine; and
- proxy or `delegatecall` upgradeability.

## Gauge policy module

`GaugeValidationModuleV1` has no constructor arguments or protocol-specific
immutables. It implements four methods:

```text
DIRECT_LP
DIRECT_OR_POOL_LP
VAULT
FACTORY_IS_VALID_GAUGE
```

Their proofs are:

```text
DIRECT_LP
    gauge.factory()
    gauge.lp_token()
    factory.get_gauge(lpToken) == gauge

DIRECT_OR_POOL_LP
    direct get_gauge(lpToken), or
    lpToken.minter() -> pool
    factory.get_gauge(pool) == gauge

VAULT
    gauge.factory()
    gauge.lp_token()
    factory.gauge_for_vault(vault) == gauge

FACTORY_IS_VALID_GAUGE
    gauge.factory()
    factory.is_valid_gauge(gauge) == true
```

All dependency calls remain gas bounded and require canonical return encoding.

## LlamaLend v2

The supported v2 gauge is a conventional factory-deployed staking gauge over a
lender-vault token. It does not require callback, AMM, LendFactory market-index,
Minter, or CRV validation.

Configure factory
`0x64e1a69732fAC63F6790b3d8a34C5D713cC623E6` under
`FACTORY_IS_VALID_GAUGE`.

Pinned regression evidence:

- chain ID `1`;
- block `25,619,622`;
- block hash
  `0x3995ff2d82e9b602f8c36a4b408e13bcda78dfdebd79e3ff87c89044569ec059`;
- observation time `2026-07-26T21:20:47Z`;
- gauge `0xbe0451815b546F705ef3f398B8179aE3AADDA14e`;
- factory ownership resolves to the Curve ownership Agent;
- `factory.is_valid_gauge(gauge) == true`;
- the gauge LP token is a canonical LlamaLend v2 lender vault; and
- ownership proposal `1461` recognizes the gauge addition as currently valid.

Manually deployed borrower-side callbacks remain unsupported unless Curve later
adopts them as a production family with a durable provenance mechanism.

## Contract and configuration changes

- Remove the callback method and its selectors, readers, constants, and
  constructor immutables from `GaugeValidationModuleV1`.
- Use `FACTORY_IS_VALID_GAUGE` as the generic validation ID for every factory
  exposing that attestation.
- Replace the LendFactory callback binding with the LlamaLend v2 vault-gauge
  factory binding.
- Reduce the initial route count from five to four while retaining twelve
  factory bindings.
- Keep `GaugeValidator` and `ProposalAnalysisModuleV1` interfaces unchanged.
- Deploy the gauge module with no arguments.
- Read back four routes, twelve bindings, ownership, and analyzer dependencies
  after deployment.

## Independent tooling

Both manifest generators must implement the four proofs independently through
direct RPC reads. They must not call the Solidity validator to derive expected
booleans.

Remove all callback-specific RPC selectors and prospective-state logic.
Generate fixtures at block `25,619,622`, including proposal `1461`.

## Tests

Required release gates:

- reciprocal positive and negative cases for every method;
- canonical boolean and address-return checks;
- zero, one, and multiple route matches;
- exact factory binding and route lifecycle;
- deployed code and exact bindings for all twelve configured factories;
- representative live gauges for every method and every configured factory
  with an available live gauge at the pinned block;
- LlamaLend v2 gauge factory ownership and attestation;
- proposal `1461` recognition and current validity;
- strict direct and Agent-wrapped proposal parsing;
- malformed callscript rejection without partial results;
- analyzer replacement, disabling, reverts, and gas exhaustion;
- deployment and inspection on the pinned fork; and
- explicit rejection of an EOA-deployed legacy gauge.

Historical manifests remain observational evidence, not exhaustive correctness
requirements.

## Verification

```sh
forge fmt --check
forge build --sizes
forge lint
RPC_URL=http://wavey:8545 forge test -vv

RPC_URL=http://wavey:8545 FORK_BLOCK=25619622 \
  node script/generate-gauge-manifest.mjs

RPC_URL=http://wavey:8545 FORK_BLOCK=25619622 \
  node script/generate-proposal-manifest.mjs

forge script script/DeployGaugeValidator.s.sol:DeployGaugeValidator \
  --rpc-url http://wavey:8545 \
  --fork-block-number 25619622 \
  -vvvv
```

No command in this plan broadcasts, deploys to mainnet, signs, or changes
protocol state.

## Acceptance criteria

- The gauge module exposes exactly four validation IDs.
- It has no callback-specific code or constructor dependencies.
- The new LlamaLend v2 gauge validates through its configured factory.
- Proposal `1461` reports one recognized, currently valid gauge addition.
- Manual LlamaLend callbacks remain out of scope.
- Exactly-one-match and fail-closed behavior remain unchanged.
- Contracts, scripts, tests, fixtures, README, AGENTS, and architecture
  documentation describe the same system.
