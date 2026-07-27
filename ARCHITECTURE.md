# Curve Gauge Validator Architecture

## Question

The validator answers one pessimistic question:

> Was this gauge deployed by a trusted factory?

```solidity
function validateGauge(address gauge) external view returns (bool);
```

`GaugeValidator` has one boolean validation entrypoint and one O(1)
factory-policy mapping. Proposal validation is a separate immutable consumer.

## Rule

`validateGauge(gauge)` returns `true` only when:

1. `gauge` is a contract;
2. `gauge.factory()` returns a canonical nonzero address;
3. that address has an exact `{module, validationId}` policy; and
4. the configured module reciprocally authenticates the gauge back to the same
   factory.

Every failed, reverting, malformed, gas-exhausting, contradictory, or
unconfigured read returns `false`.

```text
gauge
  |
  +-- no code or unreadable factory() ----------------------> false
  |
  +-- factory has no configured module ---------------------> false
  |
  +-- bounded module call fails or is malformed ------------> false
  |
  +-- module authenticates a different factory -------------> false
  |
  `-- module authenticates the same factory ----------------> true
```

Reading `gauge.factory()` alone is insufficient because any contract can
self-report a trusted address. The reciprocal check is what proves factory
provenance.

## Gauge contract

`GaugeValidator` contains:

- `mapping(address factory => FactoryPolicy) policyForFactory`;
- a bounded, strict `gauge.factory()` read;
- a bounded, strict policy-module call;
- governance ownership; and
- `validateGauge(address) returns (bool)`.

The binding is:

```solidity
struct FactoryPolicy {
    address module;
    bytes32 validationId;
}
```

A zero module means the factory is untrusted. There is no route scan, module
registry, active-ID lifecycle, ambiguity state, or caller-supplied factory
hint.

The module returns an authenticated factory address rather than a bare
boolean. The core returns `true` only when that address exactly equals the
factory reported to the core by the gauge.

Governance may bind, rebind, or revoke one factory:

```solidity
setFactoryPolicy(address factory, address module, bytes32 validationId);
```

This lets a future validation method live in a new module without replacing
the core or its immutable proposal consumer.

## Current policy module

`GaugeValidationModuleV1` is immutable, stateless, and implements the four
current reciprocal proof IDs:

```text
DIRECT_LP
DIRECT_OR_POOL_LP
VAULT
FACTORY_IS_VALID_GAUGE
```

Unknown IDs and every failed dependency return the zero address.

### Direct LP

```text
lpToken = gauge.lp_token()
factory.get_gauge(lpToken) == gauge
```

### Direct or pool LP

```text
lpToken = gauge.lp_token()

factory.get_gauge(lpToken) == gauge
    OR
factory.get_gauge(lpToken.minter()) == gauge
```

The pool fallback is attempted only when the direct lookup succeeds and
returns zero. A failed or contradictory direct lookup returns `false`.

### Vault

```text
vault = gauge.lp_token()
factory.gauge_for_vault(vault) == gauge
```

### Factory attestation

```text
factory.is_valid_gauge(gauge) == true
```

All dependency calls are capped at 30,000 gas. Address responses must be
exactly 32 bytes with zero upper bits. Boolean responses must be exactly 32
bytes and equal to zero or one.

The core caps each module call at 2,000,000 gas and requires an exact canonical
address response. Policy modules should be immutable implementations; binding
an upgradeable proxy deliberately transfers policy-change authority to that
proxy's administrator.

## Proposal contract

`ProposalGaugeValidator` is a separate, immutable consumer of
`GaugeValidator`. It stores only:

- the Curve ownership DAO;
- the ownership Agent;
- GaugeController; and
- the gauge validator.

It exposes:

```solidity
function analyzeProposal(uint256 proposalId)
    external
    view
    returns (ProposalAnalysis memory);

function validateProposal(uint256 proposalId)
    external
    view
    returns (bool);
```

The compact result is:

```solidity
enum AnalysisStatus {
    UNAVAILABLE,
    CALLSCRIPT_REJECTED,
    COMPLETE
}

struct GaugeResult {
    address gauge;
    bool valid;
}

struct ProposalAnalysis {
    AnalysisStatus status;
    bool allValid;
    GaugeResult[] gauges;
}
```

The analyzer recognizes only:

1. a direct canonical `GaugeController.add_gauge` call; or
2. a canonical ownership-Agent `execute` call whose inner target is
   GaugeController, value is zero, and payload is exactly `add_gauge`.

Unrelated calls are ignored. Malformed callscripts, gauge-shaped calls through
the wrong target, noncanonical ABI words, recursive wrappers, and more than 64
recognized gauges reject the entire analysis.

Every recognized gauge is evaluated through the immutable gauge validator
with a 2,100,000-gas cap and an exact canonical boolean return. The extra
100,000 gas lets the core perform its factory read and still forward the full
2,000,000-gas module budget under EIP-150. A failed query makes that gauge
invalid without changing a successfully parsed proposal to `UNAVAILABLE`.

`allValid` is true only when parsing completed, at least one gauge was
recognized, and every recognized gauge is valid. `validateProposal` applies
that exact rule.

Gauge booleans reflect the current block. The proposal validator does not
simulate state changes that earlier calls in the proposal would create.

The deployed contract at
`0xbEF66C2c0Cd93C00C545938Ff3f5b50b2D91ccc6` inspired the compact
`{gauge, valid}` result and false-on-empty aggregate. This implementation does
not copy its active-proposal scanning, permissive minimum-length parsing, or
unbounded dependency calls.

## Mainnet trust set

All initial bindings use `GaugeValidationModuleV1`.

| Factory family | Factory | Validation ID |
| --- | --- | --- |
| Regular gauge factory | `0x6A8cbed756804B16E05E741eDaBd5cB544AE21bf` | `DIRECT_LP` |
| crvUSD StableSwap factory | `0x4F8846Ae9380B90d2E71D5e3D042dff3E7ebb40d` | `DIRECT_LP` |
| TwoCrypto NG factory | `0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F` | `DIRECT_OR_POOL_LP` |
| Legacy TwoCrypto factory | `0xF18056Bbd320E96A48e3Fbf8bC061322531aac99` | `DIRECT_OR_POOL_LP` |
| Metapool factory | `0xB9fC157394Af804a3578134A6585C0dc9cc990d4` | `DIRECT_OR_POOL_LP` |
| Stableswap proxy | `0x855cC906dA8271Dd53879929bd226711247D5f17` | `DIRECT_OR_POOL_LP` |
| Tricrypto factory | `0x0c0e5f2fF0ff18a3be9b835635039256dC4B4963` | `DIRECT_OR_POOL_LP` |
| Lending gauge factory | `0xeA6876DDE9e3467564acBeE1Ed5bac88783205E0` | `VAULT` |
| Bridge gauge factory | `0xabC000d88f23Bb45525E447528DBF656A9D55bf5` | `FACTORY_IS_VALID_GAUGE` |
| Fraxtal gauge factory | `0xeF672bD94913CB6f1d2812a6e18c1fFdEd8eFf5c` | `FACTORY_IS_VALID_GAUGE` |
| Root gauge factory | `0x306A45a1478A000dC701A6e1f7a569afb8D9DCD6` | `FACTORY_IS_VALID_GAUGE` |
| Generic factory used by LlamaLend v2 vault gauges | `0x64e1a69732fAC63F6790b3d8a34C5D713cC623E6` | `FACTORY_IS_VALID_GAUGE` |

## LlamaLend v2 boundary

At Ethereum block `25,619,622`,
`0xbe0451815b546F705ef3f398B8179aE3AADDA14e` reports the configured generic
gauge factory, and that factory returns `is_valid_gauge(gauge) == true`.

That proves the gauge came from the trusted generic factory. It does not prove
that the LP token belongs to a canonical LlamaLend market. The generic factory
can create a first gauge for an arbitrary token, so market membership is a
different question and deliberately out of scope.

## Deployment and verification

Deployment is three transactions:

```text
new GaugeValidationModuleV1()
new GaugeValidator(governance, factoryPolicies)
new ProposalGaugeValidator(dao, agent, gaugeController, gaugeValidator)
```

The proposal contract is immutable and has no owner or policy configuration.
The deployment script reads back every immutable dependency, the gauge owner,
and each factory's exact module and validation ID.

Tests cover:

- all four proof layouts;
- rebinding a factory to a future module without replacing the core;
- every module failure and malformed return;
- untrusted and spoofing cases;
- reverting, malformed, gas-burning, and oversized return data;
- owner-only trust changes;
- direct and Agent-wrapped proposal additions;
- unavailable, rejected, complete, empty, mixed-validity, and aggregate
  proposal results;
- representative live gauges for every configured factory family;
- two representative mainnet proposals; and
- exact three-contract deployment readback on a pinned mainnet fork.

Exhaustive historical gauge or proposal coverage is not required.
