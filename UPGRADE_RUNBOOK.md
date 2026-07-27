# Upgrade Runbook

## Purpose

`GaugeValidator` is a stable, non-proxy entry point. Normal upgrades replace
factory or proposal policy, not the core:

```text
factory -> {module, methodId}
proposalModule -> stateless proposal parser
```

Governance can deploy a new stateless validation module and rebind selected
factories with `setFactoryPolicy`. The core address and its
gauge and proposal entry points remain unchanged. Governance can independently
replace the proposal parser with `setProposalModule`.

## What can change in place

| Change | Entry point address | Module address | Required action |
| --- | --- | --- | --- |
| Add a trusted factory | unchanged | unchanged | Bind it to a module and nonzero method ID |
| Replace proof logic | unchanged | changes | Deploy a module and rebind affected factories |
| Disable a factory | unchanged | unchanged | Set its policy to `{address(0), 0}` |
| Roll back proof logic | unchanged | unchanged | Restore the previous module and method ID |
| Change proposal parsing | unchanged | changes | Deploy a module and call `setProposalModule` |
| Disable proposal parsing | unchanged | cleared | Call `setProposalModule(address(0))` |
| Change entry point behavior | changes | changes | Deploy and migrate the full system |

The core deliberately has no proxy or implementation upgrade mechanism. A
core change is a migration, not a policy upgrade.

## Factory-policy upgrade procedure

### 1. Define the change

Record:

- every affected factory;
- its current `{module, methodId}`;
- its intended `{module, methodId}`;
- representative valid and invalid gauges; and
- the rollback policy.

Method ID zero is reserved. An active policy must contain a nonzero module and
nonzero method ID. The only disabled policy is `{address(0), 0}`.

### 2. Deploy and verify the module

The new module should:

- implement `IGaugeValidationModule`;
- remain stateless;
- authenticate the exact gauge and factory supplied by the core;
- return one canonical boolean;
- convert dependency failures into `false`; and
- complete within the core's 2,000,000-gas module budget.

Verify the deployed source and bytecode before proposing any binding.
Deployment alone grants the module no authority.

### 3. Test on a mainnet fork

On a recent pinned fork:

1. impersonate the validator owner;
2. apply the proposed bindings;
3. verify exact policy readback;
4. test representative valid and invalid gauges for every affected factory;
5. exercise reverts, malformed returns, gas exhaustion, and dependency
   failures; and
6. rerun the full repository test suite.

Test the final governance calldata, not only equivalent direct calls. Proposal
validation reads current state and does not simulate policy changes that an
earlier call in the same proposal would make.

### 4. Submit the governance proposal

Bundle the exact calls where possible:

```solidity
validator.setFactoryPolicy(factory, newModule, methodId);
```

Multiple bindings executed in one successful governance transaction change
atomically. Any invalid policy pair, missing factory code, missing module code,
or authorization failure reverts configuration.

Before execution, compare every proposal call against the recorded change
set. Do not infer an intended factory from a module or method ID.

### 5. Verify after execution

Read back every changed `policyForFactory` entry and confirm:

- the validator owner is unchanged;
- the configured module and method ID exactly match the proposal;
- representative valid gauges return `true`;
- representative invalid gauges return `false`; and
- the expected `FactoryPolicySet` events were emitted.

`MainnetGaugeConfiguration` and `InspectGaugeValidator` describe and inspect
the repository's expected configuration; they do not update an existing
deployment. Update the expected manifest and inspection tooling when an
upgrade creates a new or mixed-module configuration.

## Proposal-module upgrade procedure

1. Record the current proposal module for rollback.
2. Deploy a stateless `IProposalValidationModule` implementation with the
   intended immutable DAO, Agent, and GaugeController.
3. On a pinned fork, test the aggregate and detailed entry points through the
   stable `GaugeValidator` address. Include valid, invalid, mixed, malformed,
   empty, direct, and Agent-wrapped proposals.
4. Confirm detailed results preserve proposal order and attribute nonzero
   weight to the decoded gauge as `false`.
5. Submit and independently review:

```solidity
validator.setProposalModule(newProposalModule);
```

6. After execution, read back `proposalModule`, rerun representative proposal
checks, and confirm the `ProposalModuleSet` event.

Rollback by restoring the previous module. Setting the module to
`address(0)` disables both proposal entry points; calls then revert instead of
returning an ambiguous result. Gauge validation remains available.

## Rollback and emergency disable

Keep the previous stateless module address and method ID in the change record.
A rollback is another governance call:

```solidity
validator.setFactoryPolicy(factory, previousModule, previousMethodId);
```

When the correct policy is uncertain, fail closed by disabling the factory:

```solidity
validator.setFactoryPolicy(factory, address(0), 0);
```

Disabling makes gauges reporting that factory return `false`. Re-enable only
after the replacement policy has passed the same fork tests and readback.

## Release checklist

- [ ] Change set and rollback policies recorded.
- [ ] New module source and bytecode verified.
- [ ] Two-million-gas budget confirmed.
- [ ] Fork tests and full repository verification pass.
- [ ] Governance calldata independently reviewed.
- [ ] Exact post-execution policies read back.
- [ ] Representative positive and negative gauges checked.
- [ ] Configuration events monitored.
- [ ] Proposal-module aggregate and detailed results checked when applicable.
- [ ] Repository manifest and inspection tooling synchronized.
