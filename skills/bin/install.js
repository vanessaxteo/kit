#!/usr/bin/env node
'use strict'

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const SKILLS = {
  'pr-linear': [],
  'daily-summary': [],
  'weekly-summary': ['daily-summary'],
  'fill-weekly-summaries': ['weekly-summary', 'daily-summary'],
}

const home = os.homedir()
const source = path.join(__dirname, '..')
const target = path.join(home, '.agents', 'skills')

const hosts = [
  { name: 'Claude Code', root: path.join(home, '.claude') },
  { name: 'Codex', root: process.env.CODEX_HOME || path.join(home, '.codex') },
]

function tildify(p) {
  return p.startsWith(home) ? '~' + p.slice(home.length) : p
}

function sameDir(a, b) {
  try {
    return fs.realpathSync(a) === fs.realpathSync(b)
  } catch {
    return false
  }
}

function withDeps(names) {
  const out = []
  const visit = (name) => {
    if (out.includes(name)) return
    SKILLS[name].forEach(visit)
    out.push(name)
  }
  names.forEach(visit)
  return out
}

const args = process.argv.slice(2)
const flags = new Set(args.filter((a) => a.startsWith('-')))
const requested = args.filter((a) => !a.startsWith('-'))

if (flags.has('--list') || flags.has('-l')) {
  for (const [name, deps] of Object.entries(SKILLS)) {
    console.log(`  ${name.padEnd(24)}${deps.length ? `needs ${deps.join(', ')}` : ''}`)
  }
  process.exit(0)
}

if (flags.has('--help') || flags.has('-h')) {
  console.log(`Usage: npx github:vanessaxteo/skills [skill...]

Installs the named skills to ${tildify(target)} and symlinks them into whichever of
Claude Code (~/.claude/skills) and Codex ($CODEX_HOME/skills) exist. With no names,
installs all ${Object.keys(SKILLS).length}. A skill that shells out to another pulls that one in automatically.

  --list    the available skills, and what each one needs
  --help    this

Re-running updates in place. Entries in a host's skills directory that aren't our
symlinks are never touched.`)
  process.exit(0)
}

const unknown = requested.filter((name) => !(name in SKILLS))
if (unknown.length) {
  console.error(`Unknown skill${unknown.length > 1 ? 's' : ''}: ${unknown.join(', ')}`)
  console.error(`Available: ${Object.keys(SKILLS).join(', ')}`)
  process.exit(1)
}

const selected = withDeps(requested.length ? requested : Object.keys(SKILLS))
const pulled = selected.filter((skill) => !requested.includes(skill))

function copySkills() {
  if (sameDir(source, target)) {
    console.log(`Skills already at ${tildify(target)} — skipping copy.`)
    return
  }
  fs.mkdirSync(target, { recursive: true })
  for (const skill of selected) {
    const from = path.join(source, skill)
    if (!fs.existsSync(from)) {
      console.error(`Missing ${skill}/ in the package — aborting.`)
      process.exit(1)
    }
    const to = path.join(target, skill)
    const existed = fs.existsSync(to)
    fs.rmSync(to, { recursive: true, force: true })
    fs.cpSync(from, to, { recursive: true })
    console.log(`  ${existed ? 'updated' : 'installed'}  ${tildify(to)}`)
  }
}

function makeExecutable() {
  for (const skill of selected) {
    for (const sub of ['adapters', 'scripts']) {
      const dir = path.join(target, skill, sub)
      if (!fs.existsSync(dir)) continue
      for (const entry of fs.readdirSync(dir)) fs.chmodSync(path.join(dir, entry), 0o755)
    }
  }
}

function link() {
  let linked = 0
  for (const host of hosts) {
    if (!fs.existsSync(host.root)) {
      console.log(`  ${host.name} not found at ${tildify(host.root)} — skipped`)
      continue
    }
    const dir = path.join(host.root, 'skills')
    fs.mkdirSync(dir, { recursive: true })
    for (const skill of selected) {
      const from = path.join(dir, skill)
      const to = path.join(target, skill)
      let stat = null
      try {
        stat = fs.lstatSync(from)
      } catch {}
      if (stat && !(stat.isSymbolicLink() && sameDir(from, to))) {
        console.log(`  ${host.name}: ${tildify(from)} already exists — left alone`)
        continue
      }
      if (!stat) fs.symlinkSync(to, from)
      linked++
    }
    console.log(`  ${host.name}: ${tildify(dir)}`)
  }
  return linked
}

if (requested.length && pulled.length) {
  console.log(`Pulling in ${pulled.join(', ')} — required by ${requested.join(', ')}.`)
}
console.log(`Installing to ${tildify(target)}`)
copySkills()
makeExecutable()
console.log('Linking into hosts')
const linked = link()

if (linked === 0) {
  console.log(`
No host skills directory found. The skills are installed at ${tildify(target)};
symlink them yourself once Claude Code or Codex is set up.`)
  process.exit(0)
}

console.log(`
Done. Restart the host to pick up ${selected.map((s) => '/' + s).join(', ')}.
  - Config is written on first run to ~/.config/skills/.
  - Slack, Linear and Notion each need one-time setup — see the README:
    https://github.com/vanessaxteo/skills#requirements`)
