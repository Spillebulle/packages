# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

The apt and rpm archive for every desktop application under `Mine/`. It has no
runtime and no application code: a shell script that builds a static site, a
workflow that runs it, and a list of repositories to collect from. `README.md`
is the user-facing half and is kept honest; this file is the reasoning.

The house rule it implements is `../Design-Principles/STYLE-GUIDE.md` §18.
When a question here has an answer there, take it.

## Decisions

- **One archive for the whole family, not one per application.** The cost a
  user pays is per archive added, not per package installed, and it is paid at
  exactly the moment they are least invested. One archive means somebody who
  added it for Umber installs Muster with `apt install muster` and every future
  application arrives free. It also collapses the key custody problem from four
  secrets to one.
- **No state, ever.** Every publish rebuilds the site from the newest release
  of each project in `projects`. Nothing incremental, no package in git, no
  pruning job. The archive is a pure function of its inputs, which is the same
  rule the applications' own `install::detect` follows, and it means a doubtful
  archive is fixed by running the workflow again.
- **The private key lives here and nowhere else.** A project's release workflow
  can *ask* for a publish, through `repository_dispatch` with a token scoped to
  this repository's contents, and cannot sign one. That separation is the whole
  reason this is a repository rather than a step inside each application's
  release.
- **No passphrase on the key, no expiry on the key.** A passphrase stored in
  the same secret store as the key it protects is theatre; an expiry date is a
  scheduled outage on every machine that added the archive, on a date nobody
  remembers. Both are written down in `README.md` so the next person does not
  "fix" them.
- **A flat repository for apt.** No `dists/`, no components. It is the right
  shape while every application ships one build per architecture. The day one
  needs a per-distribution build it cannot express that, and the migration is a
  `dists/` tree served beside the flat one for a release or two, because the
  sources line changes on every machine that has already added it.
- **The packages enrol the machine.** Each application's `.deb` and `.rpm`
  carries the public key and writes the source file on install, so the ordinary
  route of downloading one package ends with a machine that upgrades by itself.
  The source file is written by the scriptlet rather than shipped as a
  conffile, so removing one application does not cut the others off from
  updates, and `spillebulle.sources.disabled` is the opt-out.

## Commands

```sh
bash -n tools/build-archive.sh                      # syntax
tools/build-archive.sh <packages-dir> <out-dir>     # the whole site
```

There is no test suite. The test is the workflow's two verify steps, which
serve the built site on the loopback and point a Debian container and a Fedora
container at it. **Anything that changes the archive's shape has to be proved
there**, by running the workflow by hand and reading those two steps, and a
change that makes them pass trivially (dropping a `gpgcheck`, say) has removed
the only check this repository has.

## The failure that is worth naming

A user who installed a package before the archive existed has no source file,
so their package manager will say "already the newest version" for ever and
sound authoritative doing it. That is what this whole repository is for, and
the applications' updater says it in as many words when it finds a managed
installation with no archive configured. If that message is ever softened, the
worst outcome of this design comes back.
