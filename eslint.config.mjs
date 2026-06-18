import js from '@eslint/js';
import globals from 'globals';
import tseslint from 'typescript-eslint';
import importX from 'eslint-plugin-import-x';
import prettier from 'eslint-config-prettier';

export default tseslint.config(
  // Generated, build, and vendored output is never linted.
  {
    ignores: [
      'artifacts/**',
      'cache/**',
      'typechain-types/**',
      'publish/**',
      'out-foundry/**',
      'node_modules/**',
    ],
  },

  // Base + type-aware TypeScript rules for every source file.
  js.configs.recommended,
  ...tseslint.configs.recommended,
  importX.flatConfigs.recommended,

  // Everything here runs under Node (scripts, config, tests).
  {
    languageOptions: {
      globals: {
        ...globals.node,
      },
    },
    rules: {
      // import-x's default-vs-named heuristics misfire on namespaced plugin
      // and TypeScript type-only re-exports; module correctness is covered by
      // the TypeScript compiler instead.
      'import-x/no-named-as-default': 'off',
      'import-x/no-named-as-default-member': 'off',
    },
  },

  {
    files: ['**/*.ts'],
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      '@typescript-eslint/no-floating-promises': 'error',
      'no-use-before-define': 'off',
      '@typescript-eslint/no-use-before-define': 'error',
      '@typescript-eslint/no-unused-vars': 'warn',
      // `any` is permitted, matching the prior airbnb-typescript baseline
      // (which left this rule off) used to author the test helpers and scripts.
      '@typescript-eslint/no-explicit-any': 'off',
      // TypeScript itself resolves modules and validates named/default/namespace
      // imports far more accurately than the import-x resolver, so defer those
      // checks to the compiler and keep only the import-ordering rule.
      'import-x/no-unresolved': 'off',
      'import-x/named': 'off',
      'import-x/namespace': 'off',
      'import-x/default': 'off',
      'import-x/order': [
        'error',
        {
          alphabetize: {
            order: 'asc',
            caseInsensitive: false,
          },
        },
      ],
    },
  },

  // Tests assert on expressions and intentionally re-await; relax accordingly.
  {
    files: ['test/**/*.ts'],
    rules: {
      '@typescript-eslint/no-unused-expressions': 'off',
      '@typescript-eslint/return-await': 'off',
    },
  },

  // Prettier wins on all formatting concerns. Keep this last.
  prettier,
);
