#!/usr/bin/env node
// Bundles src/entry.tsx into a single self-contained dist/entry.js.
// No runtime node_modules needed.
import { build } from 'esbuild'
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const out = resolve(root, 'dist/entry.js')

// `react-devtools-core` is only imported when DEV=true at runtime (Ink dev
// mode). Stub it out so the bundle doesn't carry the dep.
const stubDevtools = {
  name: 'stub-react-devtools-core',
  setup(b) {
    b.onResolve({ filter: /^react-devtools-core$/ }, args => ({
      path: args.path,
      namespace: 'stub-devtools'
    }))
    b.onLoad({ filter: /.*/, namespace: 'stub-devtools' }, () => ({
      contents: 'export default { initialize() {}, connectToDevTools() {} }',
      loader: 'js'
    }))
  }
}

// `tsconfig.json` uses `moduleResolution: "nodenext"`, which requires every
// relative import to spell the `.js` extension (even when the file on disk
// is `.ts`/`.tsx`). esbuild, by default, does NOT rewrite `.js` -> `.ts` for
// imports that already carry an explicit extension — it only walks
// `resolveExtensions` for extensionless imports. Without this plugin every
// `import x from '../lib/foo.js'` would fail to resolve, even though
// `foo.ts` is sitting right there. Map `.js` -> `.tsx`/`.ts`/`.jsx` on disk
// and let esbuild pick up the match. We deliberately do NOT include `.js`
// in the lookup list — if a `.ts/.tsx/.jsx` rewrite isn't available the
// resolution is left to esbuild's default path (which handles real `.js`
// files in `node_modules/` and elsewhere). All returned paths are absolute
// (esbuild rejects relative paths from resolve plugins).
const jsToTsPlugin = {
  name: 'js-to-ts',
  setup(b) {
    b.onResolve({ filter: /\.js$/ }, args => {
      if (args.namespace === 'stub-devtools') return null
      const base = args.path.replace(/\.js$/, '')
      const dir = args.resolveDir
      for (const ext of ['.tsx', '.ts', '.jsx']) {
        const candidate = resolve(dir, base + ext)
        if (existsSync(candidate) && statSync(candidate).isFile()) {
          return { path: candidate }
        }
      }
      return null
    })
  }
}

await build({
  entryPoints: [resolve(root, 'src/entry.tsx')],
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node20',
  outfile: out,
  jsx: 'automatic',
  jsxImportSource: 'react',
  // Skip the prebuilt @hermes/ink bundle — esbuild's __esm helper doesn't
  // await nested async init, which breaks lazy-initialized exports like
  // `render`. Bundling from source sidesteps that.
  alias: { '@hermes/ink': resolve(root, 'packages/hermes-ink/src/entry-exports.ts') },
  plugins: [stubDevtools, jsToTsPlugin],
  // Some transitive deps use CommonJS `require(...)` at runtime. ESM bundles
  // don't get a `require` binding automatically, so we inject one.
  banner: {
    js: "import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);"
  },
  logLevel: 'info'
})

// esbuild preserves the shebang from src/entry.tsx into the bundle, but Nix's
// patchShebangs phase mangles `/usr/bin/env -S node --foo --bar` (it strips
// the `node` token, leaving a broken interpreter). The hermes_cli launcher
// always invokes this file as `node dist/entry.js` anyway, so the shebang is
// redundant — strip it.
const body = readFileSync(out, 'utf8')
if (body.startsWith('#!')) {
  writeFileSync(out, body.slice(body.indexOf('\n') + 1))
}

console.log(`built ${out}`)
