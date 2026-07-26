# Curve Gauge Validator

A single-contract, fail-closed answer to:

> Was this gauge deployed by a trusted factory?

```solidity
validator.validateGauge(gauge); // true or false
```

The validator reads `gauge.factory()`, checks that factory against the
governance trust mapping, and requires a reciprocal factory lookup. Any
missing, malformed, reverting, or contradictory dependency returns `false`.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the proof layouts and mainnet
trust set.

## Commands

```bash
forge fmt --check
forge build --sizes
forge lint
RPC_URL=<ethereum-rpc> forge test -vv
```

Simulate the one-transaction deployment:

```bash
forge script script/DeployGaugeValidator.s.sol:DeployGaugeValidator \
  --rpc-url <ethereum-rpc> \
  --fork-block-number 25619622 \
  -vvvv
```

Inspect a deployed validator:

```bash
VALIDATOR=<address> forge script \
  script/InspectGaugeValidator.s.sol:InspectGaugeValidator \
  --rpc-url <ethereum-rpc>
```
