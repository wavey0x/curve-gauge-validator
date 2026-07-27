# Curve Gauge and Proposal Validator

A single stable entry point provides fail-closed answers for gauges and Curve
ownership proposals:

> Was this gauge deployed by a trusted factory?

```solidity
validator.validateGauge(gauge); // true or false
validator.validateProposalGauges(proposalId); // aggregate true or false
validator.analyzeProposalGauges(proposalId); // aggregate plus ordered gauge results
```

The core reads `gauge.factory()`, performs one exact
`factory -> {module, methodId}` lookup, and asks that trusted policy module
to validate the gauge against the exact reported factory. Any missing,
malformed, reverting, or contradictory dependency returns `false`.

`GaugeValidationModuleV1` contains the four current stateless proof methods.
Future methods can be deployed in new modules and bound to relevant factories
without replacing the core.

`ProposalValidationModuleV1` separately extracts authenticated gauge additions
from one Curve ownership proposal. Governance can replace that parser through
the stable validator without migrating callers.

DAO read failures revert. Structurally non-executable callscripts and unrelated
calls create no gauge risk; authenticated gauge additions return `false` when
their calldata cannot be decoded safely or the gauge fails validation. Both
executable `add_gauge` encodings are recognized: omitted or explicit zero
initial weight is accepted, while nonzero initial weight returns `false`. The
detailed method returns one ordered `{gauge, valid}` result for every safely
decoded addition.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the proof layouts and mainnet
trust set. See [UPGRADE_RUNBOOK.md](./UPGRADE_RUNBOOK.md) for policy upgrades,
rollback, emergency disablement, and the boundary between upgrades and
migrations.

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
GAUGE_MODULE=<address> PROPOSAL_MODULE=<address> VALIDATOR=<address> forge script \
  script/InspectGaugeValidator.s.sol:InspectGaugeValidator \
  --rpc-url <ethereum-rpc>
```

Analyze one proposal:

```bash
VALIDATOR=<address> PROPOSAL_ID=<id> forge script \
  script/AnalyzeProposal.s.sol:AnalyzeProposal \
  --rpc-url <ethereum-rpc>
```
