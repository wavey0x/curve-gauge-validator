# Curve Gauge and Proposal Validator

One onchain entry point validates gauge provenance and gauge additions in Curve
ownership proposals. Governance owns the core; trusted managers maintain factories.

**Prepared core:** `0x956418112dEceC17042854599dF6375E6ec70414`.
Mainnet deployment is pending.

```solidity
function validateGauge(address gauge) external view returns (bool);
function getActiveProposals() external view returns (uint256[] memory);
function validateProposalGauges(uint256 proposalId) external view returns (bool);
function analyzeProposalGauges(uint256 proposalId)
    external view returns (bool allValid, GaugeResult[] memory results);
```

The core checks `gauge.factory()` against one configured `{module, methodId}`
policy. Dependency failures or malformed responses return `false`. Proposal-read
failures revert. Detailed results contain ordered `{gauge, valid}` entries.
Proposal additions require omitted or explicit zero initial weight. `(true, [])`
means no applicable gauge additions, not approval of unrelated proposal actions.
Discovery returns every open ownership vote; validation reads current state.

Owner and managers may immediately add, rebind, disable, or restore any factory,
including choosing any module and nonzero method. Only the owner can call
`setManager`, change the proposal module, or transfer ownership. Transfer is
single-step and preserves appointments; revocation leaves installed policies intact.

The initial configuration includes twelve factories, including the LMCallback factory
`0x2191718CD32d02B8E60BAdFFeA33E4B5DD9A0A0D` using method 4. Callback provenance
can validate before AMM attachment; emissions activation is a separate condition.

Factory bindings live in [MainnetGaugeConfiguration.sol](src/MainnetGaugeConfiguration.sol).
[DeployGaugeValidator](script/DeployGaugeValidator.s.sol) holds the deployment
address, salt, and hashes. It deploys only the new core and verifies the two reused
modules against their onchain runtime hashes. Code or constructor changes require
recomputing core artifacts and updating the target address. One implementation is
maintained, with no version API; existing module names containing `V1` are retained.

## Verify and deploy

Set `RPC_URL` to your Ethereum RPC. Fork tests pin block `26,177,927` and cover
manager permissions, LMCallbacks, module reuse, and deterministic deployment.

```bash
forge fmt --check
forge build --sizes
forge lint
forge test -vv
forge script script/DeployGaugeValidator.s.sol:DeployGaugeValidator \
  --rpc-url "$RPC_URL" --fork-block-number 26177927 -vvvv
```

An authorized operator deploys from the script's pinned deployer account:

```bash
forge script script/DeployGaugeValidator.s.sol:DeployGaugeValidator \
  --rpc-url "$RPC_URL" --account wavey3 --broadcast --slow -vvvv
```

The constructor sets governance as owner and `yrisk.eth`
(`0xc0DE00005F21Fa7846BA0EA2E3F2FC4F048a72C9`) as the initial manager.
Governance adds or removes managers with `setManager(account, enabled)`.
Integrations use the new core address.

For live inspection and analysis, set `VALIDATOR`, comma-separated `FACTORIES`,
and `PROPOSAL_ID` as needed. `MANAGER` is optional for inspection. Factory and
manager inventories come from events; inspection covers only supplied factories.

```bash
forge script script/InspectGaugeValidator.s.sol:InspectGaugeValidator --rpc-url "$RPC_URL"
forge script script/AnalyzeProposal.s.sol:AnalyzeProposal --rpc-url "$RPC_URL"
```
