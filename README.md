# Spillebulle packages

The apt and rpm archive for the desktop applications: **Muster**, **Umber**,
and whatever comes next. Adding it is two commands, once, and from then on the
system package manager keeps every one of them up to date the way it keeps
everything else up to date.

This is infrastructure rather than an application, so it does not follow the
README shape in `Design-Principles/STYLE-GUIDE.md` §17.1. The rule it does
follow is §18, which is where the reasoning behind the whole arrangement lives.

Published at **https://spillebulle.github.io/packages/**.

## Adding it

Debian, Ubuntu, Mint, Pop!\_OS:

```sh
curl -fsSL https://spillebulle.github.io/packages/spillebulle-archive.asc \
  | sudo gpg --dearmor -o /usr/share/keyrings/spillebulle-archive.gpg
sudo tee /etc/apt/sources.list.d/spillebulle.sources >/dev/null <<'EOF'
Types: deb
URIs: https://spillebulle.github.io/packages/deb/
Suites: ./
Signed-By: /usr/share/keyrings/spillebulle-archive.gpg
EOF
sudo apt update
```

Fedora, RHEL, openSUSE:

```sh
sudo rpm --import https://spillebulle.github.io/packages/spillebulle-archive.asc
sudo tee /etc/yum.repos.d/spillebulle.repo >/dev/null <<'EOF'
[spillebulle]
name=Spillebulle
baseurl=https://spillebulle.github.io/packages/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://spillebulle.github.io/packages/spillebulle-archive.asc
EOF
```

**Nobody has to do either of these.** Every application's own `.deb` and `.rpm`
carries the key and writes the source itself on install, so the ordinary route,
downloading one package from a release page, ends with a machine that upgrades
by itself afterwards. The commands above are for adding the archive first and
installing from it, and for a machine that installed a package from before the
archive existed.

To opt out on a machine, delete the source and leave a marker so no package
puts it back:

```sh
sudo rm /etc/apt/sources.list.d/spillebulle.sources
sudo touch /etc/apt/sources.list.d/spillebulle.sources.disabled
```

## How it works

`tools/build-archive.sh` takes a directory of `.deb` and `.rpm` files and
writes the whole site. `.github/workflows/publish.yml` runs it, having first
downloaded the newest release of every repository in `projects`.

**The archive holds no state.** Nothing is committed, nothing is incremental,
and no package file ever enters git: every publish rebuilds the site from the
current newest release of each project and replaces what Pages is serving.
That keeps the repository small, keeps the archive reproducible from a cold
start, and means "prune the old versions" is not a job anybody has to remember.
It also means the answer to any doubt about the archive is to run the workflow
again.

The apt half is a [flat repository](https://wiki.debian.org/DebianRepository/Format#Flat_Repository_Format):
packages and index in one directory, no `dists/`, no components, a bare `./`
where a suite would go. The rpm half is `createrepo_c` output. Both are signed
with the same key, and on the rpm side the packages are signed individually as
well, so a `.rpm` handed to somebody outside the archive still carries a
signature.

Before anything is deployed, the workflow serves the built site on the loopback
and points a Debian container and a Fedora container at it: add the key, add
the source, refuse anything that does not verify, resolve an install. A broken
signature or a malformed index fails the job rather than reaching a machine.

### Running it by hand

The script is meant to be runnable on any Debian-ish box, because a release
process only a robot can run cannot be rehearsed:

```sh
sudo apt install dpkg-dev apt-utils createrepo-c rpm
gpg --quick-generate-key "Test archive <test@example.com>" default default never
ARCHIVE_KEY_ID=<the fingerprint> tools/build-archive.sh ~/Downloads /tmp/site
python3 -m http.server -d /tmp/site 8000
```

## Setting it up

Four things, once.

**1. The signing key.** RSA 4096, no expiry, and **no passphrase**:

```sh
gpg --quick-generate-key "Spillebulle archive <spillebulle@gmail.com>" rsa4096 sign never
gpg --export-secret-keys --armor <fingerprint> > archive-key.asc
```

No passphrase is deliberate. The private key lives in exactly one place, this
repository's secrets, and a passphrase stored beside the key it protects is
theatre rather than security. What guards it is that the secret is readable
only by workflows in this repository. It also makes `rpmsign` work without an
agent, a loopback pinentry or a secret on a command line.

No expiry is also deliberate. An expiry date on an archive key is a scheduled
outage on every machine that has added the archive, arriving without warning
on a date nobody remembers. Rotating it is possible and unpleasant, so keep the
private key backed up somewhere that is not a laptop.

**2. The secret.** Paste `archive-key.asc` whole into `ARCHIVE_SIGNING_KEY`
under this repository's Actions secrets, then delete the file. Nothing else
needs it, and no other repository ever gets it.

**3. Pages.** Settings, Pages, Source: **GitHub Actions**. Not a branch: the
site is an artifact, not a checkout.

**4. The dispatch token.** A fine-grained personal access token whose only
permission is **Contents: read and write** on `Spillebulle/packages`, saved as
`ARCHIVE_DISPATCH_TOKEN` in each application's repository. That is what lets a
release say "there is a new package" and nothing else. Its counterpart is the
step at the end of each `release.yml`.

## Adding a project

1. Add its repository to `projects`.
2. Give the repository the `ARCHIVE_DISPATCH_TOKEN` secret.
3. Copy the "Tell the archive" step from Muster's `release.yml` into its own.
4. Have its `.deb` and `.rpm` enrol the machine, which is
   `packaging/linux/build-packages.sh` plus `packaging/linux/spillebulle-archive.asc`
   copied across from Muster.
5. Run this workflow by hand once, and read what the two verify steps say.

## What this is not

Not Flathub, not the AUR, not Debian proper, not Fedora proper. Those are other
people's archives with other people's review queues, and the reasoning about
which of them is worth entering is in `Design-Principles/STYLE-GUIDE.md` §18.
This is the one that is entirely ours and takes an afternoon.
