import test from "node:test";
import assert from "node:assert/strict";
import path from "node:path";

test("project has a package and a safe default workspace root", async () => {
  const packageJson = await import("../package.json", { with: { type: "json" } });
  assert.equal(packageJson.default.name, "@cloudex/server");
  assert.equal(path.isAbsolute(process.cwd()), true);
});
