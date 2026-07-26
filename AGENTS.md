# Repository Guide

## Scope

This repository answers one question:

> Was this gauge deployed by a trusted factory?

Keep the deployed design to one validator contract and a pessimistic boolean
result.

## Layout

- `src/GaugeValidator.sol`: validation, reciprocal proofs, and factory trust.
- `src/MainnetGaugeConfiguration.sol`: mainnet owner and trusted factories.
- `script/DeployGaugeValidator.s.sol`: one-transaction deployment and readback.
- `script/InspectGaugeValidator.s.sol`: read-only configuration inspection.
- `test/GaugeValidator.t.sol`: proof, failure, and authorization tests.
- `test/MainnetGaugeValidation.t.sol`: pinned-fork representative gauges.
- `test/Deployment.t.sol`: deployment/readback test.

## Invariants

- A self-reported factory address is never enough.
- A factory is trusted only when `proofForFactory[factory] != Proof.NONE`.
- The configured factory must reciprocally authenticate the gauge.
- External dependency failures return `false`.
- Configuration failures revert.
- External calls remain gas bounded and ABI strict.
- Do not add proposal parsing, policy modules, route scanning, historical
  exhaustiveness, or caller-supplied factory hints to the core.

## Verification

Run:

```bash
forge fmt --check
forge build --sizes
forge lint
RPC_URL=<ethereum-rpc> forge test -vv
```
