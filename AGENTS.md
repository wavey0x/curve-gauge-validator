# Repository Guide

## Scope

This repository separates two questions:

> Was this gauge deployed by a trusted factory?

> Do all authenticated gauge additions in this proposal use a standard zero
> initial weight and currently pass that predicate?

Keep `GaugeValidator` as the stable public entry point with O(1)
factory-to-module dispatch and one replaceable proposal-module pointer. Keep
proof implementations and proposal parsing in separate stateless modules.

## Layout

- `src/GaugeValidator.sol`: stable entry point and exact module bindings.
- `src/GaugeValidationModuleV1.sol`: four current reciprocal proofs.
- `src/ProposalValidationModuleV1.sol`: active-proposal discovery, strict
  proposal parsing, aggregate boolean, and ordered gauge results.
- `src/interfaces/IProposalValidationModule.sol`: stable proposal-module ABI.
- `src/MainnetGaugeConfiguration.sol`: mainnet owner and trusted factories.
- `script/DeployGaugeValidator.s.sol`: deterministic CreateX deployment and
  readback.
- `script/InspectGaugeValidator.s.sol`: read-only configuration inspection.
- `script/AnalyzeProposal.s.sol`: read-only proposal analysis.
- `test/GaugeValidator.t.sol`: proof, failure, and authorization tests.
- `test/ProposalValidationModule.t.sol`: parser, aggregate, and detailed-result
  tests.
- `test/MainnetGaugeValidation.t.sol`: pinned-fork representative gauges.
- `test/Deployment.t.sol`: deployment/readback test.

## Mainnet deployed addresses

| Component | Address |
| --- | --- |
| `GaugeValidator` | `0x999901cd8568Caafeb8888F18C1F5B870B58b7F2` |
| `GaugeValidationModuleV1` | `0x999902533033Cc63c8128C501e307477932B742E` |
| `ProposalValidationModuleV1` | `0x9999032142B45AE92e11a5E10A45F49f58b67773` |

These are the frozen Ethereum CreateX deployment addresses. A different core
address is a migration, not an in-place upgrade.

## Invariants

- A self-reported factory address is never enough.
- A factory is trusted only when `policyForFactory[factory].module != address(0)`.
- One factory maps to exactly one packed `{module, methodId}` policy.
- Method ID zero is reserved. Policies are either active
  `{nonzero module, nonzero methodId}` or disabled `{address(0), 0}`.
- The core reads `gauge.factory()` once and passes that exact factory to the
  configured module.
- Modules are trusted, governance-selected policy components that return a
  strict boolean.
- The entry point exposes gauge validation, aggregate proposal validation, and
  ordered per-addition proposal results at one address.
- Governance can replace or disable the proposal module without changing the
  entry point. Disabled proposal validation reverts.
- Gauge and policy dependency failures return `false`; DAO proposal-read
  failures revert.
- Configuration failures revert.
- Untrusted dependency and gauge-policy calls remain gas bounded and ABI
  strict. Proposal-module failures revert.
- The proposal module has immutable DAO, Agent, and GaugeController
  dependencies and uses the calling entry point for gauge validation.
- Active-proposal discovery returns every open ownership vote and never
  filters by callscript contents.
- Authenticated proposal targets and calldata must be parsed strictly.
- Both executable `add_gauge` encodings are recognized. Omitted or explicit
  zero initial weight is accepted; nonzero initial weight returns `false`.
- Do not add proof implementations, proposal parsing, route scanning, module
  registries, status enums, historical exhaustiveness, or caller-supplied
  factory hints to `GaugeValidator`.

## Verification

Run:

```bash
forge fmt --check
forge build --sizes
forge lint
RPC_URL=http://wavey:8545 forge test -vv
```
