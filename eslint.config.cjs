const js = require("@eslint/js");
const jsdoc = require("eslint-plugin-jsdoc");
const tseslint = require("typescript-eslint");

module.exports = tseslint.config(
  {
    ignores: ["coverage/**", "dist/**", "eslint.config.cjs", "node_modules/**"],
  },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  ...tseslint.configs.strictTypeChecked,
  {
    files: ["**/*.ts"],
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: __dirname,
      },
    },
  },
  {
    files: ["src/**/*.ts"],
    plugins: { jsdoc },
    rules: {
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/no-unsafe-argument": "error",
      "@typescript-eslint/no-unsafe-assignment": "error",
      "@typescript-eslint/no-unsafe-call": "error",
      "@typescript-eslint/no-unsafe-enum-comparison": "error",
      "@typescript-eslint/no-unsafe-member-access": "error",
      "@typescript-eslint/no-unsafe-return": "error",
      "@typescript-eslint/no-non-null-assertion": "error",
      "@typescript-eslint/only-throw-error": "error",
      "@typescript-eslint/no-unnecessary-condition": "error",
      "jsdoc/require-jsdoc": [
        "error",
        {
          contexts: [
            "ExportNamedDeclaration > FunctionDeclaration",
            "ExportNamedDeclaration > ClassDeclaration",
            "ExportDefaultDeclaration > FunctionDeclaration",
            "ExportDefaultDeclaration > ClassDeclaration",
          ],
          require: {
            ArrowFunctionExpression: false,
            ClassDeclaration: false,
            ClassExpression: false,
            FunctionDeclaration: false,
            FunctionExpression: false,
            MethodDefinition: false,
          },
        },
      ],
      "no-console": "error",
      "no-debugger": "error",
      "no-throw-literal": "error",
      "no-warning-comments": [
        "error",
        {
          terms: ["TODO", "FIXME", "HACK", "XXX"],
          location: "anywhere",
        },
      ],
    },
  },
);
