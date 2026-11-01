import { build, context } from "esbuild";

const options = ["harness", "terminal"].map((name) => ({
  entryPoints: [`src/${name}.ts`],
  bundle: true,
  format: "esm",
  platform: "browser",
  outfile: `public/${name}.js`,
  logLevel: "info",
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
