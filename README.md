# Curve Gauge and Proposal Validator

A small, stable core provides a fail-closed answer to:

> Was this gauge deployed by a trusted factory?

```solidity
validator.validateGauge(gauge); // true or false
```

The core reads `gauge.factory()`, performs one exact
`factory -> {module, methodId}` lookup, and asks that trusted policy module
to validate the gauge against the exact reported factory. Any missing,
malformed, reverting, or contradictory dependency returns `false`.

`GaugeValidationModuleV1` contains the four current stateless proof methods.
Future methods can be deployed in new modules and bound to relevant factories
without replacing the core.

`ProposalGaugeValidator` separately extracts authenticated gauge additions
from one Curve ownership proposal and exposes one safety predicate:

```solidity
proposalValidator.validateProposalGauges(proposalId); // true or false
```

DAO read failures revert. Structurally non-executable callscripts and unrelated
calls create no gauge risk; authenticated gauge additions return `false` when
their calldata cannot be decoded safely or the gauge fails validation.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the proof layouts and mainnet
trust set.

## Commands

```bash
forge fmt --check
forge build --sizes
forge lint
RPC_URL=http://wavey:8545 forge test -vv
```

Simulate the three-transaction deployment:

```bash
forge script script/DeployGaugeValidator.s.sol:DeployGaugeValidator \
  --rpc-url <ethereum-rpc> \
  --fork-block-number 25619622 \
  -vvvv
```

Inspect a deployed system:

```bash
GAUGE_MODULE=<address> VALIDATOR=<address> PROPOSAL_VALIDATOR=<address> forge script \
  script/InspectGaugeValidator.s.sol:InspectGaugeValidator \
  --rpc-url <ethereum-rpc>
```

Analyze one proposal:

```bash
PROPOSAL_VALIDATOR=<address> PROPOSAL_ID=<id> forge script \
  script/AnalyzeProposal.s.sol:AnalyzeProposal \
  --rpc-url <ethereum-rpc>
```
