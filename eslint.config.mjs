import js from "@eslint/js";
import { defineConfig } from "eslint/config";
import tseslint from "typescript-eslint";

const sources = [
  "apps/mac-companion/src/**/*.ts",
  "packages/protocol/src/**/*.ts",
];
const tests = ["apps/mac-companion/test/**/*.ts"];

export default defineConfig(
  {
    ignores: [
      "**/node_modules/**",
      "apps/mac-companion/public/**",
      "**/.build/**",
    ],
  },
  {
    files: [...sources, ...tests],
    extends: [js.configs.recommended, tseslint.configs.recommended],
    linterOptions: { reportUnusedDisableDirectives: "error" },
    rules: {
      "@typescript-eslint/no-unused-vars": [
        "error",
        {
          argsIgnorePattern: "^_",
          caughtErrorsIgnorePattern: "^_",
          ignoreRestSiblings: true,
        },
      ],
    },
  },
  {
    files: sources,
    languageOptions: {
      parserOptions: {
        project: "./apps/mac-companion/tsconfig.json",
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      "@typescript-eslint/no-floating-promises": "error",
      "@typescript-eslint/no-misused-promises": "error",
      "@typescript-eslint/await-thenable": "error",
      "@typescript-eslint/switch-exhaustiveness-check": "error",
    },
  },
  {
    files: tests,
    rules: { "@typescript-eslint/no-explicit-any": "off" },
  },
);
