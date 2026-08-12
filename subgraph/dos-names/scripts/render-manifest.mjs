import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const EXPECTED_CHAIN_ID = 3939;
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const ADDRESS_PATTERN = /^0x[0-9a-fA-F]{40}$/;

const CONTRACT_PLACEHOLDERS = [
  ["dosRegistry", "__DOS_REGISTRY_ADDRESS__"],
  ["dosRegistrar", "__DOS_REGISTRAR_ADDRESS__"],
  [
    "permissionedResolverImplementation",
    "__PERMISSIONED_RESOLVER_IMPLEMENTATION_ADDRESS__",
  ],
];

export function validateDeployment(deployment) {
  if (deployment?.chainId !== EXPECTED_CHAIN_ID) {
    throw new Error(`chainId must be ${EXPECTED_CHAIN_ID}`);
  }

  if (
    !Number.isInteger(deployment.deploymentBlock) ||
    deployment.deploymentBlock < 0
  ) {
    throw new Error("deploymentBlock must be a non-negative integer");
  }
  if (
    !Number.isInteger(deployment.finalDeploymentBlock) ||
    deployment.finalDeploymentBlock < deployment.deploymentBlock
  ) {
    throw new Error(
      "finalDeploymentBlock must be an integer at or after deploymentBlock",
    );
  }
  if (deployment.smokeName !== "bens-smoke.dos") {
    throw new Error("smokeName must be bens-smoke.dos");
  }
  if (!ADDRESS_PATTERN.test(deployment.smokeResolvedAddress ?? "")) {
    throw new Error("smokeResolvedAddress must be an EVM address");
  }
  if (deployment.smokeResolvedAddress.toLowerCase() === ZERO_ADDRESS) {
    throw new Error("smokeResolvedAddress must not be the zero address");
  }

  for (const [contractName] of CONTRACT_PLACEHOLDERS) {
    const address = deployment.contracts?.[contractName];
    if (!ADDRESS_PATTERN.test(address ?? "")) {
      throw new Error(`contracts.${contractName} must be an EVM address`);
    }
    if (address.toLowerCase() === ZERO_ADDRESS) {
      throw new Error(`contracts.${contractName} must not be the zero address`);
    }
  }

  return deployment;
}

export function renderManifest(template, deployment) {
  validateDeployment(deployment);

  let rendered = template;
  for (const [contractName, placeholder] of CONTRACT_PLACEHOLDERS) {
    if (!rendered.includes(placeholder)) {
      throw new Error(`template is missing ${placeholder}`);
    }
    rendered = rendered.replaceAll(
      placeholder,
      deployment.contracts[contractName],
    );
  }

  if (!rendered.includes("__START_BLOCK__")) {
    throw new Error("template is missing __START_BLOCK__");
  }
  rendered = rendered.replaceAll(
    "__START_BLOCK__",
    String(deployment.deploymentBlock),
  );

  const unresolved = rendered.match(/__[A-Z0-9_]+__/g);
  if (unresolved) {
    throw new Error(`unresolved placeholders: ${unresolved.join(", ")}`);
  }

  return rendered;
}

function main(argv) {
  if (argv.length !== 3) {
    throw new Error(
      "usage: render-manifest.mjs <deployment.json> <template.yaml> <output.yaml>",
    );
  }

  const [deploymentPath, templatePath, outputPath] = argv;
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
  const template = fs.readFileSync(templatePath, "utf8");
  const rendered = renderManifest(template, deployment);

  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, rendered, "utf8");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2));
}
