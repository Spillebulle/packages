# Enrolment: what every package does on install

Every application's `.deb`, `.rpm` and Arch `.pkg.tar.zst` adds this archive
to the machine it is installed on, so downloading one file from a release page
ends with a machine that upgrades by itself (`Design-Principles/STYLE-GUIDE.md`
§18.2). This file is the contract: the paths, the order and the scripts, the
same in every application. Copy from here, do not re-derive.

The archive key, for every format:

```
7A9EA69E033F3C3EF4F53EB4A72BC0FD5E061ADA
Spillebulle archive <spillebulle@gmail.com>
```

Each application keeps a copy of the armoured key as
`packaging/linux/spillebulle-archive.asc`, byte for byte the archive's own.

## Rules for all three

- **Created, never overwritten.** Each file below is written only if it is
  missing, so a machine that has edited, pinned or redirected it keeps its own.
- **Never removed.** Removing one application must not cut the others off from
  updates. No uninstall scriptlet touches anything here.
- **A `.disabled` marker opts out.** If the marker beside a file exists, the
  scriptlet does nothing at all, on install and on every upgrade.
- **Never fail the install.** Every step ends `|| true`; an application that
  installs without enrolling is better than one that does not install.
- **No file is shared between packages.** dpkg refuses to install a package
  that ships a path another package already owns, even byte for byte the same
  file, so two applications can never both ship one path. Each ships its key
  under its own name and the scriptlet puts the shared copy in place.

## apt (`.deb`, `postinst`)

| What | Path |
|---|---|
| Key the package ships | `/usr/share/<app>/spillebulle-archive.gpg` (dearmoured) |
| Shared keyring, written by the scriptlet | `/etc/apt/keyrings/spillebulle-archive.gpg` |
| Source, written by the scriptlet | `/etc/apt/sources.list.d/spillebulle.sources` |
| Opt-out marker | `/etc/apt/sources.list.d/spillebulle.sources.disabled` |

```sh
sources=/etc/apt/sources.list.d/spillebulle.sources
keyring=/etc/apt/keyrings/spillebulle-archive.gpg
if [ ! -e "$sources.disabled" ]; then
    mkdir -p /etc/apt/keyrings || true
    [ -e "$keyring" ] || install -m644 /usr/share/<app>/spillebulle-archive.gpg "$keyring" || true
    # Packages from before this contract shipped the keyring at
    # /usr/share/keyrings/, which an upgrade removes; point at the shared copy.
    if [ -e "$sources" ] && grep -q '^Signed-By: /usr/share/keyrings/spillebulle-archive.gpg$' "$sources"; then
        sed -i "s|^Signed-By: /usr/share/keyrings/spillebulle-archive.gpg\$|Signed-By: $keyring|" "$sources" || true
    fi
    if [ ! -e "$sources" ]; then
        printf '%s\n' \
            'Types: deb' \
            'URIs: https://spillebulle.github.io/packages/deb/' \
            'Suites: ./' \
            "Signed-By: $keyring" > "$sources" || true
    fi
fi
```

The package no longer ships `/usr/share/keyrings/spillebulle-archive.gpg`.

## rpm (`.rpm`, `%post`)

Unchanged from before this file existed: rpm accepts identical files from
several packages, so the shared path is safe there.

| What | Path |
|---|---|
| Key the package ships | `/etc/pki/rpm-gpg/RPM-GPG-KEY-spillebulle` (armoured) |
| Repo file, written by the scriptlet | `/etc/yum.repos.d/spillebulle.repo` (`gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-spillebulle`) |
| Opt-out marker | `/etc/yum.repos.d/spillebulle.repo.disabled` |

No `rpm --import` in a scriptlet: it runs inside the transaction that holds
the rpm database and fails silently. `gpgkey=file://` is the supported route.

## pacman (`.pkg.tar.zst`, the `.install` file)

| What | Path |
|---|---|
| Key the package ships | `/usr/share/<app>/spillebulle-archive.asc` (armoured) |
| Repository settings, written by the scriptlet | `/etc/pacman.d/spillebulle` |
| Section appended to | `/etc/pacman.conf`: `[spillebulle]` + `Include = /etc/pacman.d/spillebulle` |
| Opt-out marker | `/etc/pacman.d/spillebulle.disabled` |

The section goes at the end of `pacman.conf`, after the distribution's own
repositories, so theirs win any name they share. The key is trusted with a
local signature, which is what `pacman-key` does for every third-party
repository; it is called from the scriptlet, which works (pacman's keyring is
not the package database it holds locked).

```sh
_spillebulle_archive() {
    local conf=/etc/pacman.d/spillebulle
    local fpr=7A9EA69E033F3C3EF4F53EB4A72BC0FD5E061ADA
    [ -e "$conf.disabled" ] && return 0
    # Every time, not only when the key is missing: both are idempotent, and
    # a key present but never signed (an earlier attempt that failed) would
    # otherwise stay "unknown trust" for ever and stop `pacman -Syu`.
    if command -v pacman-key >/dev/null 2>&1; then
        pacman-key --add /usr/share/<app>/spillebulle-archive.asc >/dev/null 2>&1 || true
        pacman-key --lsign-key "$fpr" >/dev/null 2>&1 || true
    fi
    if [ ! -e "$conf" ]; then
        printf '%s\n' \
            'SigLevel = Required DatabaseRequired' \
            'Server = https://spillebulle.github.io/packages/arch/$arch' > "$conf" || true
    fi
    if ! grep -q '^\[spillebulle\]' /etc/pacman.conf 2>/dev/null; then
        printf '\n[spillebulle]\nInclude = %s\n' "$conf" >> /etc/pacman.conf || true
    fi
}

post_install() {
    _spillebulle_archive
}

post_upgrade() {
    _spillebulle_archive
}
```

The PKGBUILD names it with `install=<app>.install`, and makepkg needs the file
beside the PKGBUILD. The package is `<app>-bin` with `provides=('<app>')` and
`conflicts=('<app>')`, released as `<app>-bin-<version>-1-x86_64.pkg.tar.zst`;
the archive collects every `*.pkg.tar.zst` on the newest release.

## The updater

An application that checks for updates states the same paths in its own
language, so check them (§18.3):

- apt: `/etc/apt/sources.list.d/spillebulle.sources` present means "your
  package manager has it": print `sudo apt update && sudo apt upgrade`.
- rpm: `/etc/yum.repos.d/spillebulle.repo` means `sudo dnf upgrade`.
- pacman: a `[spillebulle]` section in `/etc/pacman.conf` means
  `sudo pacman -Syu`.
- None of them: name the exact release asset for this machine, or none.

`packaging/check.sh` in each application fails if a path here and the path in
its scriptlets or updater disagree.

## Checking it

`packaging/linux/` in each application builds all three packages; its CI
installs each in a clean container (`debian`, `fedora`, `archlinux`) and
asserts what this file says: the keyring, the source, the section, the key
trusted. For apt it also installs a **second** package that enrols (a copy of
the first under another name is enough), because the defect this file exists
to prevent only shows when two applications are installed.
