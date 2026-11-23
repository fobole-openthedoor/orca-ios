#!/usr/bin/env node
// Generates App/Resources/Localizable.xcstrings from the official app's locale catalogs, keeping its keys
// (home.emptyState.title …) so every string reads word for word as the official app's.
// Usage: node scripts/generate-strings.mjs <official mobile dir>
// i18next placeholders ({{name}}) become positional %@ arguments in key order of appearance in English.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import path from 'node:path'

const [mobileDir] = process.argv.slice(2)
if (!mobileDir) {
  console.error('usage: generate-strings.mjs <official mobile dir>')
  process.exit(1)
}
const root = path.join(path.dirname(new URL(import.meta.url).pathname), '..')
const localesDir = path.join(mobileDir, 'src/i18n/locales')
// Official locale file → Apple locale identifier.
const LOCALES = { en: 'en', zh: 'zh-Hans', 'zh-Hant': 'zh-Hant' }

function flatten(object, prefix = '', out = {}) {
  for (const [key, value] of Object.entries(object)) {
    const full = prefix ? `${prefix}.${key}` : key
    if (value && typeof value === 'object') flatten(value, full, out)
    else if (typeof value === 'string') out[full] = value
  }
  return out
}

const catalogs = {}
for (const [file, locale] of Object.entries(LOCALES)) {
  catalogs[locale] = flatten(JSON.parse(readFileSync(path.join(localesDir, `${file}.json`), 'utf8')))
}

// i18next plural keys (foo_one / foo_other) collapse into one key with plural variations.
const PLURAL = /_(zero|one|two|few|many|other)$/

function toFormat(text, order) {
  return text.replace(/\{\{\s*(\w+)\s*\}\}/g, (_, name) => {
    let index = order.indexOf(name)
    if (index === -1) {
      order.push(name)
      index = order.length - 1
    }
    return name === 'count' ? `%${index + 1}$lld` : `%${index + 1}$@`
  })
}

// This client's own strings, for what the official app doesn't have (scripts/strings-extra.json, the same
// i18next shape per language); an official key always wins.
const extra = JSON.parse(readFileSync(path.join(root, 'scripts/strings-extra.json'), 'utf8'))
for (const [file, locale] of Object.entries(LOCALES)) {
  catalogs[locale] = { ...flatten(extra[file] ?? {}), ...catalogs[locale] }
}

const strings = {}
const english = catalogs.en
const baseKeys = new Set(Object.keys(english).map((key) => key.replace(PLURAL, '')))
for (const key of [...baseKeys].sort()) {
  const order = []
  // English fixes the argument order for every language.
  const englishText = english[key] ?? english[`${key}_other`]
  toFormat(englishText, order)
  const localizations = {}
  for (const locale of Object.values(LOCALES)) {
    const catalog = catalogs[locale]
    if (catalog[key] !== undefined) {
      localizations[locale] = {
        stringUnit: { state: 'translated', value: toFormat(catalog[key], [...order]) }
      }
      continue
    }
    const forms = Object.keys(catalog).filter((k) => k.replace(PLURAL, '') === key && PLURAL.test(k))
    if (forms.length === 0) continue
    const plural = {}
    for (const form of forms) {
      plural[PLURAL.exec(form)[1]] = {
        stringUnit: { state: 'translated', value: toFormat(catalog[form], [...order]) }
      }
    }
    // Xcode refuses a plural variation that never shows the number; Chinese has a single form anyway.
    const values = Object.values(plural).map((form) => form.stringUnit.value)
    if (values.length === 1 || values.some((value) => !/%\d+\$lld/.test(value))) {
      localizations[locale] = plural.other ?? Object.values(plural)[0]
      continue
    }
    localizations[locale] = { variations: { plural } }
  }
  strings[key] = { extractionState: 'manual', localizations }
}

const out = path.join(root, 'App/Resources/Localizable.xcstrings')
mkdirSync(path.dirname(out), { recursive: true })
writeFileSync(out, JSON.stringify({ sourceLanguage: 'en', strings, version: '1.0' }, null, 2) + '\n')
console.log(`wrote ${Object.keys(strings).length} keys to ${path.relative(process.cwd(), out)}`)
