# Repository Guide

## Scope

This repository separates two questions:

> Was this gauge deployed by a trusted factory?

> Do all authenticated gauge additions in this proposal currently pass that
> predicate?

Keep `GaugeValidator` to one small pessimistic boolean core with O(1)
factory-to-module dispatch. Keep proof implementations stateless and proposal
parsing in its separate immutable consumer.

## Layout

- `src/GaugeValidator.sol`: stable core and exact factory-policy bindings.
- `src/GaugeValidationModuleV1.sol`: four current reciprocal proofs.
- `src/ProposalGaugeValidator.sol`: strict proposal parsing and gauge results.
- `src/MainnetGaugeConfiguration.sol`: mainnet owner and trusted factories.
- `script/DeployGaugeValidator.s.sol`: three-contract deployment and readback.
- `script/InspectGaugeValidator.s.sol`: read-only configuration inspection.
- `script/AnalyzeProposal.s.sol`: read-only proposal analysis.
- `test/GaugeValidator.t.sol`: proof, failure, and authorization tests.
- `test/ProposalGaugeValidator.t.sol`: parser and proposal-boolean tests.
- `test/MainnetGaugeValidation.t.sol`: pinned-fork representative gauges.
- `test/Deployment.t.sol`: deployment/readback test.

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
- External dependency failures return `false`.
- Configuration failures revert.
- External calls remain gas bounded and ABI strict.
- The proposal validator has immutable dependencies and no governance policy.
- Authenticated proposal targets and calldata must be parsed strictly.
- Do not add proof implementations, proposal parsing, route scanning, module
  registries, historical exhaustiveness, or caller-supplied factory hints to
  `GaugeValidator`.

## Verification

Run:

```bash
forge fmt --check
forge build --sizes
forge lint
RPC_URL=http://wavey:8545 forge test -vv
```
