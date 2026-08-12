import assert from "node:assert/strict";
import test from "node:test";

import { renderManifest, validateDeployment } from "../scripts/render-manifest.mjs";

const VALID_DEPLOYMENT = {
  chainId: 3939,
  deploymentBlock: 68,
  finalDeploymentBlock: 72,
  smokeName: "bens-smoke.dos",
  smokeResolvedAddress: "0x4444444444444444444444444444444444444444",
  contracts: {
    dosRegistry: "0x1111111111111111111111111111111111111111",
    dosRegistrar: "0x2222222222222222222222222222222222222222",
    permissionedResolverImplementation:
      "0x3333333333333333333333333333333333333333",
  },
};

const TEMPLATE = `
network: __NETWORK__
registry: __DOS_REGISTRY_ADDRESS__
registrar: __DOS_REGISTRAR_ADDRESS__
resolver: __PERMISSIONED_RESOLVER_IMPLEMENTATION_ADDRESS__
startBlock: __START_BLOCK__
`;

test("renders every contract address and deployment block", () => {
  const rendered = renderManifest(TEMPLATE, VALID_DEPLOYMENT);

  assert.match(rendered, /0x1111111111111111111111111111111111111111/);
  assert.match(rendered, /0x2222222222222222222222222222222222222222/);
  assert.match(rendered, /0x3333333333333333333333333333333333333333/);
  assert.match(rendered, /startBlock: 68/);
  assert.match(rendered, /network: dos-testnet/);
  assert.doesNotMatch(rendered, /__[A-Z0-9_]+__/);
});

test("accepts the canonical DOS Mainnet deployment", () => {
  const deployment = {
    ...VALID_DEPLOYMENT,
    chainId: 7979,
  };

  assert.doesNotThrow(() => validateDeployment(deployment));
  assert.match(renderManifest(TEMPLATE, deployment), /network: dos-mainnet/);
});

test("rejects a deployment for an unsupported chain", () => {
  assert.throws(
    () => validateDeployment({ ...VALID_DEPLOYMENT, chainId: 1 }),
    /chainId must be one of 3939, 7979/,
  );
});

test("rejects a missing deployment block", () => {
  const deployment = { ...VALID_DEPLOYMENT };
  delete deployment.deploymentBlock;

  assert.throws(
    () => validateDeployment(deployment),
    /deploymentBlock must be a non-negative integer/,
  );
});

test("rejects a final deployment block before the first deployment block", () => {
  assert.throws(
    () =>
      validateDeployment({
        ...VALID_DEPLOYMENT,
        finalDeploymentBlock: VALID_DEPLOYMENT.deploymentBlock - 1,
      }),
    /finalDeploymentBlock must be an integer at or after deploymentBlock/,
  );
});

test("rejects a missing smoke resolution address", () => {
  const deployment = { ...VALID_DEPLOYMENT };
  delete deployment.smokeResolvedAddress;

  assert.throws(
    () => validateDeployment(deployment),
    /smokeResolvedAddress must be an EVM address/,
  );
});

test("rejects a missing required contract", () => {
  const deployment = {
    ...VALID_DEPLOYMENT,
    contracts: { ...VALID_DEPLOYMENT.contracts },
  };
  delete deployment.contracts.dosRegistrar;

  assert.throws(
    () => validateDeployment(deployment),
    /contracts\.dosRegistrar must be an EVM address/,
  );
});

test("rejects a zero contract address", () => {
  const deployment = {
    ...VALID_DEPLOYMENT,
    contracts: {
      ...VALID_DEPLOYMENT.contracts,
      dosRegistry: "0x0000000000000000000000000000000000000000",
    },
  };

  assert.throws(
    () => validateDeployment(deployment),
    /contracts\.dosRegistry must not be the zero address/,
  );
});

test("rejects a template missing a required placeholder", () => {
  assert.throws(
    () =>
      renderManifest(
        "network: __NETWORK__\nstartBlock: __START_BLOCK__",
        VALID_DEPLOYMENT,
      ),
    /template is missing __DOS_REGISTRY_ADDRESS__/,
  );
});
