# Repository guidance

- Maintain one `GaugeValidator` implementation and deployment workflow. Keep
  factory dispatch O(1), with one packed `{module, methodId}` policy per factory;
  proof logic and proposal parsing stay in separate stateless modules.
- Managers are fully trusted to manage any factory/module immediately. Manager
  administration, ownership transfer, and proposal-module changes remain owner-only.
  Keep ownership transfer single-step and preserve appointments across transfer.
- Preserve code checks, canonical active/disabled policies, gas bounds, strict ABI
  decoding, and the single `gauge.factory()` read. Gauge dependency failures return
  `false`; proposal-module/DAO read failures and configuration failures revert.
- Parse authenticated proposal calls strictly, accept only zero initial weight,
  preserve ordered gauge results, and discover all open votes regardless of script.
- Verify core deployment artifacts after bytecode/configuration changes. Identify
  reused modules by their deployed hashes, including original compiler metadata.
- README is the user documentation. Keep disposable plans and logs in `.tmp/`;
  do not commit documentation bundles or raw verification output unless requested.
- Use pinned Ethereum state through `http://wavey:8545`; expose failed/stale reads.
  Never commit credentials or signing material. Automation may prepare and simulate;
  authorized operators deploy, and Curve governance executes transactions.

Required checks:

```bash
forge fmt --check
forge build --sizes
forge lint
RPC_URL=http://wavey:8545 forge test -vv
```
