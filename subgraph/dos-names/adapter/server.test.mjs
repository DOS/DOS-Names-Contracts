import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import {
  createAdapter,
  rewriteMetadata,
  validateDeployment,
} from "./server.mjs";

const registry = "0x95366f1E44532F50c022aEefF708F424b7854173";
const node =
  "0x9726493dec81dd17125aebf46d9e1093f970402e79c96bb24d723095a247acf5";
const tokenId =
  "109853185306708996857436761598381125367517663046059027338278467513256125661184";
const config = { registry, publicOrigin: "https://test.doscan.io" };
const domain = () => ({
  id: node,
  name: "bens-smoke.dos",
  tokens: [
    {
      id: "68366885821481989290125917096282513121619573263602720883098992233964231961845",
      contract_hash: registry,
      type: "WRAPPED_DOMAIN_TOKEN",
    },
  ],
  protocol: {
    id: "dos-names",
    deployment_blockscout_base_url: "http://backend:4000/",
  },
  owner: { hash: registry },
  resolved_address: { hash: "0x99999e454138f6be73E2bE82c890bc5765749999" },
});
const graphDomain = () => ({
  id: node,
  name: "bens-smoke.dos",
  tokenId,
  owner: { id: registry },
});

test("uses the indexed ENSv2 token ID without replacing the canonical namehash", async () => {
  const result = await rewriteMetadata(domain(), config, async () =>
    graphDomain(),
  );
  assert.equal(result.tokens[0].id, tokenId);
  assert.equal(result.id, node);
  assert.equal(result.tokens[0].contract_hash, registry);
  assert.equal(
    result.protocol.deployment_blockscout_base_url,
    "https://test.doscan.io/",
  );
});

test("rewrites nested address lookup metadata and leaves unrelated protocols unchanged", async () => {
  const other = {
    protocol: {
      id: "other",
      deployment_blockscout_base_url: "https://other.example/",
    },
  };
  const result = await rewriteMetadata(
    { domain: domain(), other },
    config,
    async () => graphDomain(),
  );
  assert.equal(result.domain.tokens[0].id, tokenId);
  assert.deepEqual(result.other, other);
});

test("fails closed for missing, mismatched, or invalid token state", async () => {
  for (const state of [
    null,
    { ...graphDomain(), id: `0x${"11".repeat(32)}` },
    { ...graphDomain(), name: "other.dos" },
    { ...graphDomain(), tokenId: null },
    { ...graphDomain(), tokenId: "1e30" },
    { ...graphDomain(), tokenId: (1n << 256n).toString() },
  ]) {
    await assert.rejects(rewriteMetadata(domain(), config, async () => state));
  }
});

test("rejects token contracts that disagree with the canonical subgraph registry", async () => {
  const value = domain();
  value.tokens[0].contract_hash = "0x1111111111111111111111111111111111111111";
  await assert.rejects(
    rewriteMetadata(value, config, async () => graphDomain()),
  );
});

test("rejects numeric token IDs rather than accepting rounded JSON numbers", async () => {
  await assert.rejects(
    rewriteMetadata(domain(), config, async () => ({
      ...graphDomain(),
      tokenId: 123,
    })),
  );
});

test("preserves a subdomain registry and reads regenerated token IDs without a stale cache", async () => {
  const child = "0x1111111111111111111111111111111111111111";
  const value = domain();
  value.name = "child.bens-smoke.dos";
  value.tokens[0].contract_hash = child;
  let version = "123";
  const lookup = async () => ({
    ...graphDomain(),
    name: value.name,
    tokenId: version,
    owner: { id: child },
  });
  assert.equal(
    (await rewriteMetadata(value, config, lookup)).tokens[0].id,
    "123",
  );
  version = "456";
  assert.equal(
    (await rewriteMetadata(value, config, lookup)).tokens[0].id,
    "456",
  );
});

test("rejects non-Testnet or incomplete deployment manifests", () => {
  assert.throws(() =>
    validateDeployment({ chainId: 7979, contracts: { dosRegistry: registry } }),
  );
  assert.throws(() => validateDeployment({ chainId: 3939, contracts: {} }));
  assert.equal(
    validateDeployment({ chainId: 3939, contracts: { dosRegistry: registry } }),
    registry,
  );
});

async function listen(server) {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return `http://127.0.0.1:${server.address().port}`;
}

test("HTTP adapter fixes NFT metadata, strips credentials, and preserves status semantics", async (t) => {
  let graphUnavailable = false;
  const upstream = createServer((req, res) => {
    assert.equal(req.headers.authorization, undefined);
    assert.equal(req.headers.cookie, undefined);
    res.setHeader("content-type", "application/json");
    if (req.url === "/health") return res.end('{"status":"SERVING"}');
    if (req.url === "/missing") {
      res.statusCode = 404;
      return res.end('{"message":"Not found"}');
    }
    res.setHeader("etag", '"upstream-etag"');
    res.end(JSON.stringify(domain()));
  });
  const graph = createServer(async (req, res) => {
    let body = "";
    for await (const chunk of req) body += chunk;
    assert.equal(JSON.parse(body).variables.id, node);
    res.setHeader("content-type", "application/json");
    res.end(
      JSON.stringify(
        graphUnavailable
          ? { errors: [{ message: "unavailable" }] }
          : {
              data: {
                domain: graphDomain(),
                _meta: { hasIndexingErrors: false },
              },
            },
      ),
    );
  });
  const upstreamUrl = await listen(upstream);
  const graphqlUrl = await listen(graph);
  const adapter = createAdapter({ ...config, upstreamUrl, graphqlUrl });
  const url = await listen(adapter);
  t.after(async () => {
    for (const server of [adapter, graph, upstream]) {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    }
  });
  const response = await fetch(`${url}/api/v1/3939/domains/bens-smoke.dos`, {
    headers: { authorization: "test-fixture", cookie: "test-fixture" },
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("etag"), null);
  assert.equal((await response.json()).tokens[0].id, tokenId);
  assert.equal((await fetch(`${url}/missing`)).status, 404);
  assert.deepEqual(await (await fetch(`${url}/health`)).json(), {
    status: "SERVING",
  });
  graphUnavailable = true;
  assert.equal(
    (await fetch(`${url}/api/v1/3939/domains/bens-smoke.dos`)).status,
    502,
  );
  assert.equal(
    (await fetch(`${url}/health`, { method: "DELETE" })).status,
    405,
  );
});
