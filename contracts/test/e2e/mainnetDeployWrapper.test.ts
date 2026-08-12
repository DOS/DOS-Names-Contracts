import { describe, expect, it } from "bun:test";
import { resolve } from "node:path";

const wrapperPath = resolve(
  import.meta.dir,
  "../../script/foundry/Invoke-DeployDOSMainnet.ps1",
);

describe("DOS Mainnet deployment wrapper", () => {
  it("never passes the private key through process arguments", async () => {
    const wrapper = await Bun.file(wrapperPath).text();

    expect(wrapper).not.toContain("--private-key");
    expect(wrapper).not.toContain("wallet address");
    expect(wrapper).toContain('$env:PRIVATE_KEY = $privateKey');
    expect(wrapper).toContain(
      'forge script "script/foundry/DeployDOSMainnet.s.sol:DeployDOSMainnet"',
    );
  });
});
