# Curve Gauge and Proposal Validator

> **Trustless execution, stable integration.** Validation runs entirely
> onchain from contract state and bounded static calls—no API, indexer,
> backend, offchain allowlist, or caller-supplied proof is involved.
> Integrators call one stable core address. Curve governance manages the trust
> policy and can add, replace, or remove verifier modules without changing that
> address or requiring integrations to call modules directly.

A single stable entry point provides fail-closed answers for gauges and Curve
ownership proposals:

> Was this gauge deployed by a trusted factory?

```solidity
validator.validateGauge(gauge); // true or false
validator.getActiveProposals(); // every open ownership proposal
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
from one Curve ownership proposal. It also exposes every currently open
ownership proposal, without filtering by callscript contents. Governance can
replace that parser and discovery policy through the stable validator without
migrating the validator entry point.

The validator forwards discovery and analysis to its current proposal module,
so integrations need only the stable core address and ABI.

DAO read failures revert. Structurally non-executable callscripts and unrelated
calls create no gauge risk; authenticated gauge additions return `false` when
their calldata cannot be decoded safely or the gauge fails validation. Both
executable `add_gauge` encodings are recognized: omitted or explicit zero
initial weight is accepted, while nonzero initial weight returns `false`. The
detailed method returns one ordered `{gauge, valid}` result for every safely
decoded addition. A well-formed proposal without gauge additions returns
`(true, [])`: it creates no gauge risk, but that result is not an endorsement
of the proposal's unrelated actions.

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

Simulate the deterministic three-transaction deployment:

```bash
forge script script/DeployGaugeValidator.s.sol:DeployGaugeValidator \
  --rpc-url http://wavey:8545 \
  --fork-block-number 25625109 \
  -vvvv
```

Broadcast from the pinned `wavey3` deployer
(`0x2C2dc95F8C8060a7e3B354c1B9540881AEa1613C`):

```bash
forge script script/DeployGaugeValidator.s.sol:DeployGaugeValidator \
  --rpc-url http://wavey:8545 \
  --account wavey3 \
  --broadcast \
  --slow \
  -vvvv
```

The script deploys through the canonical CreateX factory and is safe to rerun
after a partial deployment. It rejects the wrong chain, a changed CreateX
runtime, changed init code or constructor arguments, unexpected code at a
target, and any computed-address mismatch. Its frozen Ethereum addresses are:

```text
GaugeValidator              0x999901076BB47Ae96d135C567610270d006B8684
GaugeValidationModuleV1     0x999902533033Cc63c8128C501e307477932B742E
ProposalValidationModuleV1  0x999903ff5AC376e8CEc3F9055Ed3a1A7E71f3ab7
```

Inspect a deployed system:

```bash
GAUGE_MODULE=0x999902533033Cc63c8128C501e307477932B742E \
PROPOSAL_MODULE=0x999903ff5AC376e8CEc3F9055Ed3a1A7E71f3ab7 \
VALIDATOR=0x999901076BB47Ae96d135C567610270d006B8684 forge script \
  script/InspectGaugeValidator.s.sol:InspectGaugeValidator \
  --rpc-url http://wavey:8545
```

Analyze one proposal:

```bash
VALIDATOR=<address> PROPOSAL_ID=<id> forge script \
  script/AnalyzeProposal.s.sol:AnalyzeProposal \
  --rpc-url <ethereum-rpc>
```
