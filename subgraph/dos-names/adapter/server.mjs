import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";

const MAX_BYTES = 2 * 1024 * 1024;
const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const DOMAIN_ID = /^0x[0-9a-fA-F]{64}$/;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const MAX_UINT256 = (1n << 256n) - 1n;

export function validateDeployment(deployment) {
  const registry = deployment?.contracts?.dosRegistry;
  if (
    deployment?.chainId !== 3939 ||
    !ADDRESS.test(registry ?? "") ||
    /^0x0{40}$/i.test(registry)
  ) {
    throw new Error("A nonzero Testnet 3939 registry is required");
  }
  return registry;
}

export async function rewriteMetadata(value, config, lookup) {
  let lookups = 0;
  async function walk(item, depth = 0) {
    if (depth > 16) throw new Error("Metadata nesting exceeds the limit");
    if (Array.isArray(item))
      return Promise.all(item.map((entry) => walk(entry, depth + 1)));
    if (item === null || typeof item !== "object") return item;
    const result = Object.fromEntries(
      await Promise.all(
        Object.entries(item).map(async ([key, entry]) => [
          key,
          await walk(entry, depth + 1),
        ]),
      ),
    );
    if (item.protocol?.id === "dos-names") {
      result.protocol.deployment_blockscout_base_url = `${config.publicOrigin}/`;
      if (Array.isArray(item.tokens) && item.tokens.length) {
        if (!DOMAIN_ID.test(item.id ?? "") || ++lookups > 50)
          throw new Error("Invalid domain metadata");
        const indexed = await lookup(item.id);
        if (
          indexed?.id?.toLowerCase() !== item.id.toLowerCase() ||
          indexed?.name !== item.name
        )
          throw new Error("Canonical ENSv2 domain identity is unavailable");
        if (
          indexed.tokenId === null &&
          indexed.owner?.id?.toLowerCase() === ZERO_ADDRESS &&
          indexed.wrappedOwner?.id?.toLowerCase() === ZERO_ADDRESS
        ) {
          result.tokens = [];
          return result;
        }
        if (
          typeof indexed?.tokenId !== "string" ||
          !/^[0-9]{1,78}$/.test(indexed?.tokenId ?? "") ||
          BigInt(indexed.tokenId) === 0n ||
          BigInt(indexed.tokenId) > MAX_UINT256
        )
          throw new Error("Canonical ENSv2 token state is unavailable");
        result.tokens = item.tokens.map((token) => {
          if (
            token.type !== "WRAPPED_DOMAIN_TOKEN" ||
            !ADDRESS.test(indexed.owner?.id ?? "") ||
            token.contract_hash?.toLowerCase() !==
              indexed.owner.id.toLowerCase()
          ) {
            throw new Error(
              "Token contract does not match the canonical subgraph registry",
            );
          }
          return { ...token, id: indexed.tokenId };
        });
      }
    }
    if (item.id === "dos-names" && "deployment_blockscout_base_url" in item) {
      result.deployment_blockscout_base_url = `${config.publicOrigin}/`;
    }
    return result;
  }
  return walk(value);
}

async function readLimited(stream) {
  const chunks = [];
  let length = 0;
  for await (const chunk of stream ?? []) {
    length += chunk.length;
    if (length > MAX_BYTES) throw new Error("Payload exceeds the limit");
    chunks.push(Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}

export function createAdapter(config) {
  const upstream = new URL(config.upstreamUrl);
  const graph = new URL(config.graphqlUrl);
  if (
    !ADDRESS.test(config.registry) ||
    config.publicOrigin !== "https://test.doscan.io"
  ) {
    throw new Error("Adapter must target the public Testnet explorer");
  }
  let active = 0;
  const server = createServer(
    { maxHeaderSize: 16 * 1024 },
    async (req, res) => {
      if (!["GET", "POST"].includes(req.method)) {
        res.writeHead(405, { allow: "GET, POST" });
        return res.end();
      }
      if (active >= 16) {
        res.writeHead(503);
        return res.end();
      }
      active++;
      try {
        if (!req.url?.startsWith("/") || req.url.startsWith("//"))
          throw new Error("Invalid path");
        const target = new URL(req.url, upstream);
        if (target.origin !== upstream.origin)
          throw new Error("Upstream origin mismatch");
        const signal = AbortSignal.timeout(10_000);
        const body = req.method === "POST" ? await readLimited(req) : undefined;
        const response = await fetch(target, {
          method: req.method,
          headers: {
            accept: "application/json",
            "content-type": "application/json",
          },
          body,
          signal,
          redirect: "manual",
        });
        let bytes = await readLimited(response.body);
        if (
          response.ok &&
          response.headers.get("content-type")?.includes("application/json")
        ) {
          const lookup = async (id) => {
            const graphResponse = await fetch(graph, {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({
                query:
                  "query Token($id: ID!) { domain(id: $id) { id name tokenId owner { id } wrappedOwner { id } } _meta { hasIndexingErrors } }",
                variables: { id },
              }),
              signal,
              redirect: "error",
            });
            if (!graphResponse.ok) throw new Error("Graph Node is unavailable");
            const result = JSON.parse(
              (await readLimited(graphResponse.body)).toString("utf8"),
            );
            if (
              result.errors?.length ||
              result.data?._meta?.hasIndexingErrors !== false
            )
              throw new Error("Subgraph indexing is unavailable");
            return result.data.domain;
          };
          const metadata = await rewriteMetadata(
            JSON.parse(bytes.toString("utf8")),
            config,
            lookup,
          );
          bytes = Buffer.from(JSON.stringify(metadata));
        }
        for (const header of ["content-type", "cache-control", "retry-after"]) {
          const value = response.headers.get(header);
          if (value) res.setHeader(header, value);
        }
        res.setHeader("content-length", bytes.length);
        res.writeHead(response.status);
        res.end(bytes);
      } catch {
        res.writeHead(502, {
          "content-type": "application/json",
          "cache-control": "no-store",
        });
        res.end('{"message":"ENSv2 metadata is temporarily unavailable"}');
      } finally {
        active--;
      }
    },
  );
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  return server;
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  const deployment = JSON.parse(
    readFileSync(
      process.env.DOS_NAMES_DEPLOYMENT ?? "/app/deployment.json",
      "utf8",
    ),
  );
  const registry = validateDeployment(deployment);
  createAdapter({
    registry,
    publicOrigin: "https://test.doscan.io",
    upstreamUrl: "http://bens:8050",
    graphqlUrl: "http://bens-graph-node:8000/subgraphs/name/dos-names",
  }).listen(8050, "0.0.0.0", () =>
    console.log("DOS Names Testnet metadata adapter listening"),
  );
}
