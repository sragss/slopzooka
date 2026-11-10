import { build, context } from "esbuild";
import { createHash } from "node:crypto";
import fs from "node:fs/promises";

const options = ["harness", "terminal"].map((name) => ({
  entryPoints: [`src/${name}.ts`],
  bundle: true,
  format: "esm",
  platform: "browser",
  outfile: `public/${name}.js`,
  logLevel: "info",
  write: false,
  define: { __SLOPZOOKA_BUILD_ID__: JSON.stringify("__SLZ_BUILD_HASH__") },
  plugins: [
    {
      name: "build-identity",
      setup(builder) {
        builder.onEnd(async (result) => {
          if (result.errors.length) return;
          for (const output of result.outputFiles) {
            const id = createHash("sha256")
              .update(output.contents)
              .digest("hex");
            await fs.writeFile(
              output.path,
              output.text.replaceAll("__SLZ_BUILD_HASH__", id),
            );
          }
        });
      },
    },
  ],
}));

if (process.argv.includes("--watch")) {
  const contexts = await Promise.all(options.map((option) => context(option)));
  await Promise.all(contexts.map((builder) => builder.watch()));
  console.log(
    "Watching web assets. Use Reload Content in the headset; keep the companion running.",
  );
} else {
  await Promise.all(options.map((option) => build(option)));
}
