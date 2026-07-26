# Curve Gauge Validator Architecture

## Question

The validator answers one pessimistic question:

> Was this gauge deployed by a trusted factory?

```solidity
function validateGauge(address gauge) external view returns (bool);
```

It has one deployed contract, one boolean validation entrypoint, and one
factory-trust mapping.

## Rule

`validateGauge(gauge)` returns `true` only when:

1. `gauge` is a contract;
2. `gauge.factory()` returns a canonical nonzero address;
3. that address is configured as a trusted factory; and
4. the trusted factory reciprocally authenticates the gauge using its
   configured proof.

Every failed, reverting, malformed, gas-exhausting, contradictory, or
unconfigured read returns `false`.

```text
gauge
  |
  +-- no code or unreadable factory() ----------------------> false
  |
  +-- factory not trusted ----------------------------------> false
  |
  +-- reciprocal factory proof fails -----------------------> false
  |
  `-- reciprocal factory proof succeeds --------------------> true
```

Reading `gauge.factory()` alone is insufficient because any contract can
self-report a trusted address. The reciprocal check is what proves factory
provenance.

## Contract

`GaugeValidator` contains:

- `mapping(address factory => Proof proof) proofForFactory`;
- the four small proof implementations;
- bounded, strict ABI reads;
- governance ownership; and
- `validateGauge(address) returns (bool)`.

There is no policy module, proposal analyzer, route scan, validation-ID
lifecycle, ambiguity state, or caller-supplied factory hint.

The proof enum is:

```solidity
enum Proof {
    NONE,
    DIRECT_LP,
    DIRECT_OR_POOL_LP,
    VAULT,
    FACTORY_IS_VALID_GAUGE
}
```

`NONE` means the factory is not trusted.

## Reciprocal proofs

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

## Mainnet trust set

| Factory family | Factory | Proof |
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

Governance owns the validator. It can add, change, or remove a factory with:

```solidity
setFactoryTrust(address factory, Proof proof);
```

Setting `Proof.NONE` removes trust.

## LlamaLend v2 boundary

At Ethereum block `25,619,622`,
`0xbe0451815b546F705ef3f398B8179aE3AADDA14e` reports the configured generic
gauge factory, and that factory returns `is_valid_gauge(gauge) == true`.

That proves the gauge came from the trusted generic factory. It does not prove
that the LP token belongs to a canonical LlamaLend market. The generic factory
can create a first gauge for an arbitrary token, so market membership is a
different question and deliberately out of scope.

## Deployment and verification

Deployment is one transaction:

```text
new GaugeValidator(governance, trustedFactories)
```

The deployment script reads back the owner and every configured factory proof.
Tests cover:

- all four proof layouts;
- untrusted and spoofing cases;
- reverting, malformed, gas-burning, and oversized return data;
- owner-only trust changes;
- representative live gauges for every configured factory family; and
- exact deployment readback on a pinned mainnet fork.

Exhaustive historical gauge or proposal coverage is not required.
