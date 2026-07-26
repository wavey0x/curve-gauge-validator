#!/usr/bin/env node

import {readFile, writeFile} from "node:fs/promises";

const RPC_URL = process.env.RPC_URL ?? "http://wavey:8545";
const BLOCK_NUMBER = Number(process.env.FORK_BLOCK ?? "25619622");
const INPUT = new URL("../test/data/gauge-history.json", import.meta.url);
const OUTPUT = new URL("../test/data/gauge-manifest.json", import.meta.url);
const EXPECTED_BLOCK_HASH =
  "0x3995ff2d82e9b602f8c36a4b408e13bcda78dfdebd79e3ff87c89044569ec059";

const SELECTOR = {
  factory: "0xc45a0155",
  lpToken: "0x82c63066",
  getGauge: "0xdaf297b9",
  minter: "0x07546172",
  gaugeForVault: "0x50c1163a",
  isValidGauge: "0x4b920379",
};

const FACTORY_METHOD = new Map(
  [
    ["0x6a8cbed756804b16e05e741edabd5cb544ae21bf", "DIRECT_LP"],
    ["0x4f8846ae9380b90d2e71d5e3d042dff3e7ebb40d", "DIRECT_LP"],
    ["0x98ee851a00abee0d95d08cf4ca2bdce32aeaaf7f", "DIRECT_OR_POOL_LP"],
    ["0xf18056bbd320e96a48e3fbf8bc061322531aac99", "DIRECT_OR_POOL_LP"],
    ["0xb9fc157394af804a3578134a6585c0dc9cc990d4", "DIRECT_OR_POOL_LP"],
    ["0x855cc906da8271dd53879929bd226711247d5f17", "DIRECT_OR_POOL_LP"],
    ["0x0c0e5f2ff0ff18a3be9b835635039256dc4b4963", "DIRECT_OR_POOL_LP"],
    ["0xea6876dde9e3467564acbee1ed5bac88783205e0", "VAULT"],
    [
      "0xabc000d88f23bb45525e447528dbf656a9d55bf5",
      "FACTORY_IS_VALID_GAUGE",
    ],
    [
      "0xef672bd94913cb6f1d2812a6e18c1ffded8eff5c",
      "FACTORY_IS_VALID_GAUGE",
    ],
    [
      "0x306a45a1478a000dc701a6e1f7a569afb8d9dcd6",
      "FACTORY_IS_VALID_GAUGE",
    ],
    [
      "0x64e1a69732fac63f6790b3d8a34c5d713cc623e6",
      "FACTORY_IS_VALID_GAUGE",
    ],
  ],
);

let nextId = 1;

async function rpc(method, params) {
  const response = await fetch(RPC_URL, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({jsonrpc: "2.0", id: nextId++, method, params}),
  });
  if (!response.ok) throw new Error(`RPC HTTP ${response.status}`);
  const body = await response.json();
  if (body.error) throw new Error(`${method}: ${body.error.message}`);
  return body.result;
}

async function rpcBatch(requests) {
  const output = new Array(requests.length);
  for (let start = 0; start < requests.length; start += 100) {
    const chunk = requests.slice(start, start + 100);
    const payload = chunk.map((request, index) => ({
      jsonrpc: "2.0",
      id: nextId + index,
      method: request.method,
      params: request.params,
    }));
    nextId += chunk.length;

    const response = await fetch(RPC_URL, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify(payload),
    });
    if (!response.ok) throw new Error(`RPC batch HTTP ${response.status}`);

    const bodies = await response.json();
    const byId = new Map(bodies.map((body) => [body.id, body]));
    for (let index = 0; index < payload.length; index++) {
      const body = byId.get(payload[index].id);
      output[start + index] = body && !body.error ? body.result : null;
    }
  }
  return output;
}

function blockTag() {
  return `0x${BLOCK_NUMBER.toString(16)}`;
}

function callRequest(to, data) {
  return {
    method: "eth_call",
    params: [{to, data}, blockTag()],
  };
}

function addressArgument(address) {
  return address.toLowerCase().slice(2).padStart(64, "0");
}

function callWithAddress(selector, address) {
  return `${selector}${addressArgument(address)}`;
}

function decodeAddress(value) {
  if (
    typeof value !== "string" ||
    value.length !== 66 ||
    value.slice(2, 26) !== "0".repeat(24)
  ) {
    return null;
  }
  const address = `0x${value.slice(26).toLowerCase()}`;
  return address === "0x0000000000000000000000000000000000000000"
    ? null
    : address;
}

function decodeBool(value) {
  if (value === `0x${"0".repeat(63)}1`) return true;
  if (value === `0x${"0".repeat(64)}`) return false;
  return null;
}

function validationId(method) {
  if (!method) return `0x${"0".repeat(64)}`;
  return `0x${Buffer.from(method).toString("hex").padEnd(64, "0")}`;
}

async function callsFor(addresses, selector, argumentAddresses = null) {
  const requests = addresses.map((address, index) =>
    callRequest(
      address,
      argumentAddresses
        ? callWithAddress(selector, argumentAddresses[index])
        : selector,
    ),
  );
  return rpcBatch(requests);
}

const history = JSON.parse(await readFile(INPUT, "utf8"));
const gauges = Object.keys(history).sort((a, b) =>
  a.toLowerCase().localeCompare(b.toLowerCase()),
);
const normalizedGauges = gauges.map((gauge) => gauge.toLowerCase());

const block = await rpc("eth_getBlockByNumber", [blockTag(), false]);
if (!block || Number(BigInt(block.number)) !== BLOCK_NUMBER) {
  throw new Error(`RPC did not return block ${BLOCK_NUMBER}`);
}
if (BLOCK_NUMBER === 25_619_622 && block.hash.toLowerCase() !== EXPECTED_BLOCK_HASH) {
  throw new Error(`unexpected pinned block hash ${block.hash}`);
}

const chainId = Number(BigInt(await rpc("eth_chainId", [])));
if (chainId !== 1) throw new Error(`expected Ethereum chain ID 1, got ${chainId}`);

const codes = await rpcBatch(
  normalizedGauges.map((gauge) => ({
    method: "eth_getCode",
    params: [gauge, blockTag()],
  })),
);
const factoryWords = await callsFor(normalizedGauges, SELECTOR.factory);
const lpTokenWords = await callsFor(normalizedGauges, SELECTOR.lpToken);

const observedFactories = factoryWords.map(decodeAddress);
const lpTokens = lpTokenWords.map(decodeAddress);

const directIndexes = [];
const vaultIndexes = [];
const factoryAttestedIndexes = [];
for (let index = 0; index < gauges.length; index++) {
  const method = FACTORY_METHOD.get(observedFactories[index]);
  if (
    (method === "DIRECT_LP" || method === "DIRECT_OR_POOL_LP") &&
    lpTokens[index]
  ) {
    directIndexes.push(index);
  }
  if (method === "VAULT" && lpTokens[index]) vaultIndexes.push(index);
  if (method === "FACTORY_IS_VALID_GAUGE") {
    factoryAttestedIndexes.push(index);
  }
}

const directResults = await callsFor(
  directIndexes.map((index) => observedFactories[index]),
  SELECTOR.getGauge,
  directIndexes.map((index) => lpTokens[index]),
);
const directMatches = new Set();
const poolCandidateIndexes = [];
for (let i = 0; i < directIndexes.length; i++) {
  const index = directIndexes[i];
  if (decodeAddress(directResults[i]) === normalizedGauges[index]) {
    directMatches.add(index);
  } else if (
    FACTORY_METHOD.get(observedFactories[index]) === "DIRECT_OR_POOL_LP"
  ) {
    poolCandidateIndexes.push(index);
  }
}

const minterResults = await callsFor(
  poolCandidateIndexes.map((index) => lpTokens[index]),
  SELECTOR.minter,
);
const poolIndexes = [];
const pools = [];
for (let i = 0; i < poolCandidateIndexes.length; i++) {
  const pool = decodeAddress(minterResults[i]);
  if (pool) {
    poolIndexes.push(poolCandidateIndexes[i]);
    pools.push(pool);
  }
}
const poolResults = await callsFor(
  poolIndexes.map((index) => observedFactories[index]),
  SELECTOR.getGauge,
  pools,
);
const poolMatches = new Set();
for (let i = 0; i < poolIndexes.length; i++) {
  if (decodeAddress(poolResults[i]) === normalizedGauges[poolIndexes[i]]) {
    poolMatches.add(poolIndexes[i]);
  }
}

const vaultResults = await callsFor(
  vaultIndexes.map((index) => observedFactories[index]),
  SELECTOR.gaugeForVault,
  vaultIndexes.map((index) => lpTokens[index]),
);
const vaultMatches = new Set();
for (let i = 0; i < vaultIndexes.length; i++) {
  if (decodeAddress(vaultResults[i]) === normalizedGauges[vaultIndexes[i]]) {
    vaultMatches.add(vaultIndexes[i]);
  }
}

const factoryAttestedResults = await callsFor(
  factoryAttestedIndexes.map((index) => observedFactories[index]),
  SELECTOR.isValidGauge,
  factoryAttestedIndexes.map((index) => normalizedGauges[index]),
);
const factoryAttestedMatches = new Set();
for (let i = 0; i < factoryAttestedIndexes.length; i++) {
  if (decodeBool(factoryAttestedResults[i]) === true) {
    factoryAttestedMatches.add(factoryAttestedIndexes[i]);
  }
}

const cases = {};
const counts = {};
for (let index = 0; index < gauges.length; index++) {
  const gauge = gauges[index];
  const observedFactory = observedFactories[index];
  const configuredMethod = FACTORY_METHOD.get(observedFactory);
  const matches = [];

  if (directMatches.has(index)) {
    matches.push({factory: observedFactory, method: configuredMethod});
  } else if (poolMatches.has(index)) {
    matches.push({factory: observedFactory, method: "DIRECT_OR_POOL_LP"});
  } else if (vaultMatches.has(index)) {
    matches.push({factory: observedFactory, method: "VAULT"});
  } else if (factoryAttestedMatches.has(index)) {
    matches.push({
      factory: observedFactory,
      method: "FACTORY_IS_VALID_GAUGE",
    });
  }

  let reason;
  if (matches.length === 1) reason = "unique_reciprocal_match";
  else if (matches.length > 1) reason = "ambiguous_multiple_matches";
  else if (codes[index] === "0x") reason = "no_code_at_pinned_block";
  else if (configuredMethod) {
    reason = "configured_factory_reciprocal_check_failed";
  } else if (observedFactory) {
    reason = "unsupported_factory";
  } else {
    reason = "no_readable_factory";
  }

  const match = matches.length === 1 ? matches[0] : null;
  cases[gauge] = {
    approved_block: history[gauge].approved_block,
    expected_factory:
      match?.factory ?? "0x0000000000000000000000000000000000000000",
    expected_module: match ? "GaugeValidationModuleV1" : "",
    expected_validation_id: validationId(match?.method),
    expected_valid: Boolean(match),
    observed_factory:
      observedFactory ?? "0x0000000000000000000000000000000000000000",
    reason,
  };
  counts[reason] = (counts[reason] ?? 0) + 1;
}

const manifest = {
  metadata: {
    chain_id: chainId,
    block_number: BLOCK_NUMBER,
    block_hash: block.hash,
    observed_at_utc: new Date(Number(BigInt(block.timestamp)) * 1000).toISOString(),
    case_count: gauges.length,
    reason_counts: Object.fromEntries(
      Object.entries(counts).sort(([a], [b]) => a.localeCompare(b)),
    ),
  },
  cases,
};

await writeFile(OUTPUT, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(
  JSON.stringify({
    output: OUTPUT.pathname,
    block: BLOCK_NUMBER,
    blockHash: block.hash,
    cases: gauges.length,
    counts: manifest.metadata.reason_counts,
  }),
);
