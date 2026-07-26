#!/usr/bin/env node

import {writeFile} from "node:fs/promises";

const RPC_URL = process.env.RPC_URL ?? "http://wavey:8545";
const BLOCK_NUMBER = Number(process.env.FORK_BLOCK ?? "25619622");
const OUTPUT = new URL("../test/data/proposal-manifest.json", import.meta.url);

const DAO = "0xe478de485ad2fe566d49342cbd03e49ed7db3356";
const AGENT = "0x40907540d8a6c65c637785e8f8b742ae6b0b9968";
const GAUGE_CONTROLLER = "0x2f50d538606fa9edd2b11e2446beb18c9d5846bb";

const VOTES_LENGTH_SELECTOR = "0xde4f6347";
const GET_VOTE_SELECTOR = "0x5a55c1f0";
const ADD_GAUGE_SELECTOR = "18dfe921";
const EXECUTE_SELECTOR = "b61d27f6";
const MAX_RECOGNIZED_GAUGE_ADDITIONS = 64;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

const SELECTOR = {
  factory: "0xc45a0155",
  lpToken: "0x82c63066",
  getGauge: "0xdaf297b9",
  minter: "0x07546172",
  gaugeForVault: "0x50c1163a",
  isValidGauge: "0x4b920379",
};

const FACTORY_METHOD = new Map([
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
]);

let nextRpcId = 1;

async function rpc(method, params) {
  const response = await fetch(RPC_URL, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: nextRpcId++,
      method,
      params,
    }),
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
      id: nextRpcId + index,
      method: request.method,
      params: request.params,
    }));
    nextRpcId += chunk.length;

    const response = await fetch(RPC_URL, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify(payload),
    });
    if (!response.ok) throw new Error(`RPC batch HTTP ${response.status}`);

    const bodies = await response.json();
    const byId = new Map(bodies.map((body) => [body.id, body]));
    for (let index = 0; index < chunk.length; index++) {
      const body = byId.get(payload[index].id);
      output[start + index] = body && !body.error ? body.result : null;
    }
  }

  return output;
}

function blockTag() {
  return `0x${BLOCK_NUMBER.toString(16)}`;
}

function uintArgument(value) {
  return BigInt(value).toString(16).padStart(64, "0");
}

function addressArgument(address) {
  return address.slice(2).padStart(64, "0");
}

function callRequest(to, data) {
  return {
    method: "eth_call",
    params: [{to, data}, blockTag()],
  };
}

function callWithAddress(selector, address) {
  return `${selector}${addressArgument(address)}`;
}

async function callsFor(addresses, selector, argumentAddresses = null) {
  return rpcBatch(
    addresses.map((address, index) =>
      callRequest(
        address,
        argumentAddresses
          ? callWithAddress(selector, argumentAddresses[index])
          : selector,
      ),
    ),
  );
}

function decodeUintWord(value) {
  if (typeof value !== "string" || value.length < 66) return null;
  return BigInt(`0x${value.slice(2, 66)}`);
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
  return address === ZERO_ADDRESS ? null : address;
}

function decodeBool(value) {
  if (value === `0x${"0".repeat(63)}1`) return true;
  if (value === `0x${"0".repeat(64)}`) return false;
  return null;
}

function decodeVote(value) {
  if (typeof value !== "string" || value.length < 2 + 10 * 64) return null;

  const hex = value.slice(2);
  const word = (index) =>
    BigInt(`0x${hex.slice(index * 64, (index + 1) * 64)}`);
  const dynamicOffset = Number(word(9));
  if (dynamicOffset % 32 !== 0 || dynamicOffset + 32 > hex.length / 2) {
    return null;
  }

  const length = Number(
    BigInt(`0x${hex.slice(dynamicOffset * 2, dynamicOffset * 2 + 64)}`),
  );
  const scriptStart = dynamicOffset * 2 + 64;
  if (scriptStart + length * 2 > hex.length) return null;

  return {
    snapshotBlock: Number(word(3)),
    script: Buffer.from(hex.slice(scriptStart, scriptStart + length * 2), "hex"),
  };
}

function readWord(buffer, offset) {
  if (offset + 32 > buffer.length) return null;
  return BigInt(`0x${buffer.subarray(offset, offset + 32).toString("hex")}`);
}

function readAddressWord(buffer, offset) {
  const word = readWord(buffer, offset);
  if (word === null || word >> 160n !== 0n) return null;
  return `0x${word.toString(16).padStart(40, "0")}`;
}

function readInt128Word(buffer, offset) {
  const word = readWord(buffer, offset);
  if (word === null) return null;

  const mask = (1n << 128n) - 1n;
  const lower = word & mask;
  const negative = (lower >> 127n) === 1n;
  const upper = word >> 128n;
  if ((!negative && upper !== 0n) || (negative && upper !== mask)) {
    return null;
  }

  return negative ? lower - (1n << 128n) : lower;
}

function selectorAt(buffer, offset) {
  if (offset + 4 > buffer.length) return "";
  return buffer.subarray(offset, offset + 4).toString("hex");
}

function parseAddGauge(buffer, offset, length) {
  if (length !== 100) return null;

  const gauge = readAddressWord(buffer, offset + 4);
  const gaugeType = readInt128Word(buffer, offset + 36);
  const initialWeight = readWord(buffer, offset + 68);
  if (gauge === null || gaugeType === null || initialWeight === null) return null;

  return {
    gauge,
    gauge_type: gaugeType.toString(),
    initial_weight: initialWeight.toString(),
  };
}

function parseAgentExecute(buffer, offset, length) {
  if (length < 132) return {valid: false};

  const target = readAddressWord(buffer, offset + 4);
  const value = readWord(buffer, offset + 36);
  const payloadOffset = readWord(buffer, offset + 68);
  const payloadLengthWord = readWord(buffer, offset + 100);
  if (
    target === null ||
    value === null ||
    payloadOffset !== 96n ||
    payloadLengthWord === null
  ) {
    return {valid: false};
  }

  const payloadLength = Number(payloadLengthWord);
  const available = length - 132;
  if (payloadLength > available) return {valid: false};

  const paddedLength = Math.ceil(payloadLength / 32) * 32;
  if (length !== 132 + paddedLength) return {valid: false};

  const payloadStart = offset + 132;
  for (let index = payloadLength; index < paddedLength; index++) {
    if (buffer[payloadStart + index] !== 0) return {valid: false};
  }

  const innerSelector = selectorAt(buffer, payloadStart);
  if (innerSelector === EXECUTE_SELECTOR) return {valid: false};
  if (innerSelector !== ADD_GAUGE_SELECTOR) {
    return {valid: true, addition: null};
  }
  if (target !== GAUGE_CONTROLLER || value !== 0n) return {valid: false};

  const addition = parseAddGauge(buffer, payloadStart, payloadLength);
  return addition
    ? {valid: true, addition}
    : {valid: false};
}

function executePayloadStartsWithAddGauge(buffer, offset, length) {
  if (length < 132) return false;

  const payloadOffset = readWord(buffer, offset + 68);
  const payloadLength = readWord(buffer, offset + 100);
  if (
    payloadOffset !== 96n ||
    payloadLength === null ||
    payloadLength < 4n ||
    payloadLength > BigInt(length - 132)
  ) {
    return false;
  }

  return selectorAt(buffer, offset + 132) === ADD_GAUGE_SELECTOR;
}

function parseCallscript(script) {
  const rejected = {complete: false, additions: []};
  if (
    script.length < 4 ||
    script.subarray(0, 4).toString("hex") !== "00000001"
  ) {
    return rejected;
  }

  const additions = [];
  let offset = 4;
  while (offset < script.length) {
    if (script.length - offset < 24) return rejected;

    const target = `0x${script.subarray(offset, offset + 20).toString("hex")}`;
    const callLength = script.readUInt32BE(offset + 20);
    const callOffset = offset + 24;
    if (callLength > script.length - callOffset) return rejected;

    const selector = selectorAt(script, callOffset);
    let parsed = {valid: true, addition: null};

    if (target === GAUGE_CONTROLLER && selector === ADD_GAUGE_SELECTOR) {
      const addition = parseAddGauge(script, callOffset, callLength);
      parsed = addition
        ? {valid: true, addition}
        : {valid: false, addition: null};
    } else if (selector === EXECUTE_SELECTOR) {
      const execute = parseAgentExecute(script, callOffset, callLength);
      if (target === AGENT) {
        parsed = execute;
      } else if (
        execute.addition ||
        executePayloadStartsWithAddGauge(script, callOffset, callLength)
      ) {
        parsed = {valid: false, addition: null};
      }
    } else if (selector === ADD_GAUGE_SELECTOR) {
      parsed = {valid: false, addition: null};
    }

    if (!parsed.valid) return rejected;
    if (parsed.addition) {
      if (additions.length === MAX_RECOGNIZED_GAUGE_ADDITIONS) {
        return rejected;
      }
      additions.push(parsed.addition);
    }

    offset = callOffset + callLength;
  }

  return {complete: true, additions};
}

async function resolveCurrentGaugeValidity(gauges) {
  const results = new Map();
  if (gauges.length === 0) return results;

  const codes = await rpcBatch(
    gauges.map((gauge) => ({
      method: "eth_getCode",
      params: [gauge, blockTag()],
    })),
  );
  const factories = (await callsFor(gauges, SELECTOR.factory)).map(decodeAddress);
  const lpTokens = (await callsFor(gauges, SELECTOR.lpToken)).map(decodeAddress);

  const matches = gauges.map(() => []);
  const directIndexes = [];
  const vaultIndexes = [];
  const factoryAttestedIndexes = [];

  for (let index = 0; index < gauges.length; index++) {
    const method = FACTORY_METHOD.get(factories[index]);
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
    directIndexes.map((index) => factories[index]),
    SELECTOR.getGauge,
    directIndexes.map((index) => lpTokens[index]),
  );
  const poolCandidateIndexes = [];
  for (let i = 0; i < directIndexes.length; i++) {
    const index = directIndexes[i];
    if (decodeAddress(directResults[i]) === gauges[index]) {
      matches[index].push(FACTORY_METHOD.get(factories[index]));
    } else if (FACTORY_METHOD.get(factories[index]) === "DIRECT_OR_POOL_LP") {
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
    poolIndexes.map((index) => factories[index]),
    SELECTOR.getGauge,
    pools,
  );
  for (let i = 0; i < poolIndexes.length; i++) {
    const index = poolIndexes[i];
    if (decodeAddress(poolResults[i]) === gauges[index]) {
      matches[index].push("DIRECT_OR_POOL_LP");
    }
  }

  const vaultResults = await callsFor(
    vaultIndexes.map((index) => factories[index]),
    SELECTOR.gaugeForVault,
    vaultIndexes.map((index) => lpTokens[index]),
  );
  for (let i = 0; i < vaultIndexes.length; i++) {
    const index = vaultIndexes[i];
    if (decodeAddress(vaultResults[i]) === gauges[index]) {
      matches[index].push("VAULT");
    }
  }

  const factoryAttestedResults = await callsFor(
    factoryAttestedIndexes.map((index) => factories[index]),
    SELECTOR.isValidGauge,
    factoryAttestedIndexes.map((index) => gauges[index]),
  );
  for (let i = 0; i < factoryAttestedIndexes.length; i++) {
    const index = factoryAttestedIndexes[i];
    if (decodeBool(factoryAttestedResults[i]) === true) {
      matches[index].push("FACTORY_IS_VALID_GAUGE");
    }
  }

  for (let index = 0; index < gauges.length; index++) {
    const hasCode = typeof codes[index] === "string" && codes[index] !== "0x";
    results.set(gauges[index], hasCode && matches[index].length === 1);
  }

  return results;
}

const chainId = Number(BigInt(await rpc("eth_chainId", [])));
if (chainId !== 1) throw new Error(`expected Ethereum chain ID 1, got ${chainId}`);

const block = await rpc("eth_getBlockByNumber", [blockTag(), false]);
const votesLengthResult = await rpc("eth_call", [
  {to: DAO, data: VOTES_LENGTH_SELECTOR},
  blockTag(),
]);
const votesLength = Number(decodeUintWord(votesLengthResult));

const voteResults = await rpcBatch(
  Array.from({length: votesLength}, (_, proposalId) =>
    callRequest(DAO, `${GET_VOTE_SELECTOR}${uintArgument(proposalId)}`),
  ),
);

const parsedProposals = new Map();
const uniqueGauges = new Set();
let directAdditionCount = 0;
let wrappedAdditionCount = 0;

for (let proposalId = 0; proposalId < votesLength; proposalId++) {
  const vote = decodeVote(voteResults[proposalId]);
  if (!vote) throw new Error(`could not decode proposal ${proposalId}`);

  const parsed = parseCallscript(vote.script);
  const containsGaugeSelector = vote.script
    .toString("hex")
    .includes(ADD_GAUGE_SELECTOR);
  if (!containsGaugeSelector && parsed.additions.length === 0) continue;

  for (const addition of parsed.additions) uniqueGauges.add(addition.gauge);

  if (parsed.complete) {
    let offset = 4;
    while (offset < vote.script.length) {
      const target =
        `0x${vote.script.subarray(offset, offset + 20).toString("hex")}`;
      const callLength = vote.script.readUInt32BE(offset + 20);
      const callOffset = offset + 24;
      const selector = selectorAt(vote.script, callOffset);

      if (target === GAUGE_CONTROLLER && selector === ADD_GAUGE_SELECTOR) {
        directAdditionCount++;
      } else if (target === AGENT && selector === EXECUTE_SELECTOR) {
        const payloadLength = readWord(vote.script, callOffset + 100);
        if (
          payloadLength !== null &&
          payloadLength >= 4n &&
          selectorAt(vote.script, callOffset + 132) === ADD_GAUGE_SELECTOR
        ) {
          wrappedAdditionCount++;
        }
      }

      offset = callOffset + callLength;
    }
  }

  parsedProposals.set(proposalId, {vote, parsed});
}

const currentValidity = await resolveCurrentGaugeValidity([...uniqueGauges]);
const proposals = {};
for (const [proposalId, {vote, parsed}] of parsedProposals) {
  const additions = parsed.additions.map((addition) => ({
    ...addition,
    currently_valid: currentValidity.get(addition.gauge) ?? false,
  }));

  proposals[String(proposalId)] = {
    snapshot_block: vote.snapshotBlock,
    analysis_status: parsed.complete ? "COMPLETE" : "CALLSCRIPT_REJECTED",
    all_recognized_gauge_additions_currently_valid:
      parsed.complete &&
      additions.length > 0 &&
      additions.every((addition) => addition.currently_valid),
    recognized_gauge_addition_count: additions.length,
    recognized_gauge_additions: additions,
  };
}

const manifest = {
  metadata: {
    chain_id: chainId,
    block_number: BLOCK_NUMBER,
    block_hash: block.hash,
    observed_at_utc: new Date(
      Number(BigInt(block.timestamp)) * 1000,
    ).toISOString(),
    votes_length: votesLength,
    proposal_case_count: Object.keys(proposals).length,
    unique_recognized_gauge_count: uniqueGauges.size,
    direct_recognized_addition_count: directAdditionCount,
    wrapped_recognized_addition_count: wrappedAdditionCount,
    semantics: "current_state_only",
  },
  proposals,
};

await writeFile(OUTPUT, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(
  JSON.stringify({
    output: OUTPUT.pathname,
    votesLength,
    proposalCases: Object.keys(proposals).length,
    uniqueGauges: uniqueGauges.size,
    directAdditions: directAdditionCount,
    wrappedAdditions: wrappedAdditionCount,
  }),
);
