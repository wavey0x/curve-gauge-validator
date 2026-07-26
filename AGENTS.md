# Repository Guide

## Scope

This repository separates two questions:

> Was this gauge deployed by a trusted factory?

> Do all authenticated gauge additions in this proposal currently pass that
> predicate?

Keep gauge validation to one small pessimistic boolean contract. Keep proposal
parsing in its separate immutable consumer.

## Layout

- `src/GaugeValidator.sol`: validation, reciprocal proofs, and factory trust.
- `src/ProposalGaugeValidator.sol`: strict proposal parsing and gauge results.
- `src/MainnetGaugeConfiguration.sol`: mainnet owner and trusted factories.
- `script/DeployGaugeValidator.s.sol`: two-contract deployment and readback.
- `script/InspectGaugeValidator.s.sol`: read-only configuration inspection.
- `script/AnalyzeProposal.s.sol`: read-only proposal analysis.
- `test/GaugeValidator.t.sol`: proof, failure, and authorization tests.
- `test/ProposalGaugeValidator.t.sol`: parser and proposal-result tests.
- `test/MainnetGaugeValidation.t.sol`: pinned-fork representative gauges.
- `test/Deployment.t.sol`: deployment/readback test.

## Invariants

- A self-reported factory address is never enough.
- A factory is trusted only when `proofForFactory[factory] != Proof.NONE`.
- The configured factory must reciprocally authenticate the gauge.
- External dependency failures return `false`.
- Configuration failures revert.
- External calls remain gas bounded and ABI strict.
- The proposal validator has immutable dependencies and no governance policy.
- Authenticated proposal targets and calldata must be parsed strictly.
- Do not add proposal parsing, policy modules, route scanning, historical
  exhaustiveness, or caller-supplied factory hints to `GaugeValidator`.

## Verification

Run:

```bash
forge fmt --check
forge build --sizes
forge lint
RPC_URL=<ethereum-rpc> forge test -vv
```
