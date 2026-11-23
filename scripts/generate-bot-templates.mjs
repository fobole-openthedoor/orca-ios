#!/usr/bin/env node
// Generates App/Resources/BotTemplates.json from the official built-in bot templates
// (src/shared/bots/bot-templates.ts), so New bot › Use template offers the same catalog.
// Usage: node scripts/generate-bot-templates.mjs <official orca dir>
// Needs esbuild: it uses gateway/node_modules/.bin/esbuild (cd gateway && npm install), else one on PATH.
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const [orcaDir] = process.argv.slice(2)
if (!orcaDir) {
  console.error('usage: generate-bot-templates.mjs <official orca dir>')
  process.exit(1)
}
const root = path.join(path.dirname(new URL(import.meta.url).pathname), '..')
const local = path.join(root, 'gateway/node_modules/.bin/esbuild')
const esbuild = existsSync(local) ? local : 'esbuild'
const work = mkdtempSync(path.join(tmpdir(), 'bot-templates-'))
try {
  const bundle = path.join(work, 'templates.mjs')
  execFileSync(esbuild, [
    path.join(orcaDir, 'src/shared/bots/bot-templates.ts'),
    '--bundle', '--format=esm', '--platform=node', `--outfile=${bundle}`, '--log-level=warning'
  ])
  const { BOT_TEMPLATES, BOT_TEMPLATE_CATEGORIES } = await import(pathToFileURL(bundle).href)
  const templates = BOT_TEMPLATES.map((t) => ({
    id: t.id,
    category: t.category,
    name: t.name,
    line: t.line,
    firstChat: t.firstChat,
    mascot: t.mascot,
    watches: t.watches,
    does: t.does,
    reports: t.reports,
    skills: [...t.skills],
    connectors: [...t.connectors],
    schedules: t.schedules.map((s) => ({ id: s.id, when: s.when, what: s.what })),
    ...(t.needsSetup ? { needsSetup: t.needsSetup } : {}),
    example: [...t.example]
  }))
  const out = path.join(root, 'App/Resources/BotTemplates.json')
  writeFileSync(out, JSON.stringify({ categories: [...BOT_TEMPLATE_CATEGORIES], templates }, null, 2) + '\n')
  console.log(`wrote ${templates.length} templates to ${path.relative(process.cwd(), out)}`)
} finally {
  rmSync(work, { recursive: true, force: true })
}
