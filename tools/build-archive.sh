#!/bin/bash
# Build the house package archive from a directory of built packages.
#
#   tools/build-archive.sh <packages-dir> <out-dir>
#
#   packages-dir  holds .deb, .rpm and .pkg.tar.zst files, in any layout
#   out-dir       is written from scratch: this is the whole Pages site
#
# The archive is a **pure function of the packages handed to it**. Nothing is
# carried over from the last run, nothing is committed, and no state lives
# between builds: every publish downloads the newest release of every project
# in `projects` and rebuilds the site from those files alone. That is what
# keeps the repository free of binaries and the archive reproducible from a
# cold start, and it is why "prune the old versions" is not a job anybody has
# to remember to do.
#
# Runnable on any Debian-ish box, not only in CI, which is the point: a release
# process only a robot can run cannot be rehearsed. On Ubuntu or Pop!_OS:
#
#   sudo apt install dpkg-dev apt-utils createrepo-c rpm pacman-package-manager libarchive-tools zstd
#   gpg --quick-generate-key "Test archive <test@example.com>" default default never
#   ARCHIVE_KEY_ID=<the fingerprint> tools/build-archive.sh ~/packages /tmp/site
#   python3 -m http.server -d /tmp/site 8000
#
# and then point a throwaway container at http://<host>:8000/deb.

set -euo pipefail

if [ $# -ne 2 ]; then
    sed -n '2,8p' "$0" >&2
    exit 2
fi

incoming=$(cd -- "$1" && pwd)
out=$2

# --- who the archive says it is ----------------------------------------------
#
# `Origin` and `Label` are what apt prints when it lists where a package came
# from, and what a pin in `/etc/apt/preferences.d` matches on. They are part of
# the published interface: changing either one later invalidates every pin
# anybody has written, so they are set once, here, and left alone.
ORIGIN=Spillebulle
LABEL=Spillebulle
SUITE=stable
DESCRIPTION="Spillebulle desktop applications"
BASE_URL=https://spillebulle.github.io/packages
KEYNAME=spillebulle-archive

# The signing key. Named explicitly where there is more than one secret key in
# the keyring, and otherwise the only one there, which is the shape of both a
# CI runner and a rehearsal box.
key=${ARCHIVE_KEY_ID:-}
if [ -z "$key" ]; then
    key=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10; exit }')
fi
if [ -z "$key" ]; then
    echo "no signing key: set ARCHIVE_KEY_ID, or import one into the keyring" >&2
    exit 1
fi
echo "==> signing with $key"

for tool in dpkg-scanpackages apt-ftparchive createrepo_c rpmsign gpg repo-add bsdtar; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing $tool (apt install dpkg-dev apt-utils createrepo-c rpm pacman-package-manager libarchive-tools zstd)" >&2
        exit 1
    }
done

rm -rf "$out"
mkdir -p "$out"
out=$(cd "$out" && pwd)

# GitHub Pages runs Jekyll over a site unless told not to, and Jekyll drops
# every path beginning with an underscore or a dot. `repodata/` survives that
# today and there is no reason to depend on it continuing to.
touch "$out/.nojekyll"

# --- the key itself ----------------------------------------------------------
#
# Published in both shapes, because the two package managers want different
# ones: apt wants the dearmoured binary keyring named by `Signed-By`, and rpm
# wants the ASCII-armoured block that `rpm --import` reads. Both are also what
# the packages themselves carry, so a machine that installs a package never
# fetches a key over the network at all.
gpg --export --armor "$key" > "$out/$KEYNAME.asc"
gpg --export "$key" > "$out/$KEYNAME.gpg"

# --- the apt archive ---------------------------------------------------------
#
# A **flat repository**: the packages and their index sit in one directory,
# with no `dists/` and `pool/` hierarchy and no components. Apt has supported
# this form for as long as it has existed and it is the right shape for an
# archive that carries one build per architecture of a handful of applications.
# The sources entry names it with a bare `./` where a suite would go.
#
# The day one application needs a per-distribution build, a bookworm one and a
# noble one against different glibc, this cannot express it and the archive
# grows a `dists/` tree. That is a change to the sources line on every machine
# that has already added it, so both layouts would be served side by side for a
# release or two. It is written down here rather than discovered then.
deb=$out/deb
mkdir -p "$deb"
found=0
while IFS= read -r -d '' package; do
    cp "$package" "$deb/"
    found=$((found + 1))
done < <(find "$incoming" -name "*.deb" -print0)
echo "==> $found .deb"
[ "$found" -gt 0 ] || { echo "no .deb files in $incoming" >&2; exit 1; }

(
    cd "$deb"
    # `--multiversion` so an archive that ever carries two versions of one
    # package indexes both rather than silently dropping one.
    dpkg-scanpackages --multiversion . > Packages
    gzip -9kf Packages

    # Written elsewhere and moved in, because `apt-ftparchive release`
    # checksums every file in the directory, including a Release file left
    # over from a previous run, which would then be a checksum of itself.
    apt-ftparchive \
        -o "APT::FTPArchive::Release::Origin=$ORIGIN" \
        -o "APT::FTPArchive::Release::Label=$LABEL" \
        -o "APT::FTPArchive::Release::Suite=$SUITE" \
        -o "APT::FTPArchive::Release::Codename=$SUITE" \
        -o "APT::FTPArchive::Release::Architectures=amd64 arm64" \
        -o "APT::FTPArchive::Release::Description=$DESCRIPTION" \
        release . > "$out/Release.tmp"
    mv "$out/Release.tmp" Release

    # `InRelease` is the signature wrapped around the document; `Release.gpg`
    # is the detached form. Modern apt asks for the first and falls back to the
    # second, and an archive that publishes only one of them works right up
    # until it meets the other apt.
    gpg --batch --yes --local-user "$key" --clearsign --output InRelease Release
    gpg --batch --yes --local-user "$key" --detach-sign --armor --output Release.gpg Release
)

# --- the rpm archive ---------------------------------------------------------
#
# Both halves are signed, and they are different signatures over different
# things. `rpmsign` puts one inside each package, which is what `gpgcheck=1`
# verifies at install time; the detached signature over `repomd.xml` is what
# `repo_gpgcheck=1` verifies before dnf trusts the index at all. Publishing the
# metadata signature alone would still be a complete chain, since repomd names
# the checksum of primary.xml and that names the checksum of every package, but
# the packages would then be unsigned in their own right and one handed to
# somebody outside the archive would carry nothing.
rpm=$out/rpm
mkdir -p "$rpm"
found=0
while IFS= read -r -d '' package; do
    cp "$package" "$rpm/"
    found=$((found + 1))
done < <(find "$incoming" -name "*.rpm" -print0)
echo "==> $found .rpm"
[ "$found" -gt 0 ] || { echo "no .rpm files in $incoming" >&2; exit 1; }

# The key is generated without a passphrase, deliberately: see README.md. So
# this needs no agent, no loopback pinentry and no secret on a command line.
rpmsign --define "_gpg_name $key" \
        --define "_gpg_digest_algo sha256" \
        --addsign "$rpm"/*.rpm
createrepo_c --quiet "$rpm"
gpg --batch --yes --local-user "$key" \
    --detach-sign --armor --output "$rpm/repodata/repomd.xml.asc" \
    "$rpm/repodata/repomd.xml"

# --- the pacman archive ------------------------------------------------------
#
# A pacman repository named `spillebulle`, one directory per architecture so
# the `Server` line can say `$arch` and an aarch64 build can join later without
# a change on any machine. Pacman finds the database by the repository's name,
# so `spillebulle.db` is part of the published interface, like Origin above.
#
# Signed in both places pacman checks with `SigLevel = Required
# DatabaseRequired`: a detached `.sig` beside every package, and one beside the
# database. Same key as apt and rpm.
#
# Pages serves files, not symlinks, so the links `repo-add` makes from
# `spillebulle.db` to `spillebulle.db.tar.gz` are replaced with copies, and the
# signatures copied alongside. An architecture with nothing in it still gets
# an empty, signed database: a machine that added the repository must get "no
# packages" from it, never a 404 that stops `pacman -Syu` for everything else.
REPO=spillebulle
for parch in x86_64; do
    dir=$out/arch/$parch
    mkdir -p "$dir"
    found=0
    while IFS= read -r -d '' package; do
        cp "$package" "$dir/"
        found=$((found + 1))
    done < <(find "$incoming" \( -name "*-$parch.pkg.tar.zst" -o -name "*-any.pkg.tar.zst" \) -print0)
    echo "==> $found .pkg.tar.zst for $parch"
    (
        cd "$dir"
        if [ "$found" -gt 0 ]; then
            for package in *.pkg.tar.zst; do
                gpg --batch --yes --local-user "$key" --detach-sign --no-armor \
                    --output "$package.sig" "$package"
            done
            repo-add --quiet "$REPO.db.tar.gz" ./*.pkg.tar.zst
        else
            bsdtar -czf "$REPO.db.tar.gz" -T /dev/null
            bsdtar -czf "$REPO.files.tar.gz" -T /dev/null
        fi
        for db in db files; do
            gpg --batch --yes --local-user "$key" --detach-sign --no-armor \
                --output "$REPO.$db.tar.gz.sig" "$REPO.$db.tar.gz"
            rm -f "$REPO.$db" "$REPO.$db.sig"
            cp "$REPO.$db.tar.gz" "$REPO.$db"
            cp "$REPO.$db.tar.gz.sig" "$REPO.$db.sig"
        done
        rm -f ./*.old ./*.old.sig
    )
done

# --- the page ----------------------------------------------------------------
#
# The site is a Pages site whether or not anybody reads it, so it may as well
# say what it is and hand over the two commands. Written by the build rather
# than checked in, so the list of applications is the list actually in the
# archive.
packages=$(
    cd "$deb"
    for f in *.deb; do
        name=${f%%_*}
        version=${f#*_}
        version=${version%%_*}
        echo "$name $version"
    done | sort -u
)

{
    cat <<'HEAD'
<title>Spillebulle packages</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: dark; --bg:#111315; --panel:#171a1d; --line:#24282c;
          --text:#e6e8ea; --muted:#8b9297; --accent:#5ec8d8; }
  body { margin:0; padding:48px 24px; background:var(--bg); color:var(--text);
         font:15px/1.6 Archivo, "Segoe UI", system-ui, sans-serif; }
  main { max-width:720px; margin:0 auto; }
  h1 { font-size:22px; font-weight:900; margin:0 0 4px; letter-spacing:-0.01em; }
  h2 { font-size:13px; font-weight:700; margin:36px 0 10px; color:var(--muted); }
  p { margin:0 0 12px; color:var(--muted); }
  pre { background:var(--panel); border:1px solid var(--line); border-radius:8px;
        padding:14px 16px; overflow-x:auto; font:12.5px/1.7 ui-monospace,
        "Cascadia Mono", Consolas, monospace; color:var(--text); }
  table { border-collapse:collapse; width:100%; font-size:13px; }
  td { border-bottom:1px solid var(--line); padding:7px 0; }
  td+td { text-align:right; color:var(--muted);
          font-family:ui-monospace, "Cascadia Mono", Consolas, monospace; }
  a { color:var(--accent); }
  footer { margin-top:44px; font-size:12px; color:var(--muted); }
</style>
<main>
<h1>Spillebulle packages</h1>
<p>An apt, rpm and pacman archive for the desktop applications, so a package manager
keeps them up to date the way it keeps everything else up to date. Adding it is
two commands, once, and it covers every application here and every one that
comes later.</p>
HEAD

    echo '<h2>What is in it</h2>'
    echo '<table>'
    while read -r name version; do
        [ -n "$name" ] || continue
        printf '<tr><td>%s</td><td>%s</td></tr>\n' "$name" "$version"
    done <<< "$packages"
    echo '</table>'

    cat <<HTML
<h2>Debian, Ubuntu, Mint</h2>
<pre>sudo install -d /etc/apt/keyrings
curl -fsSL $BASE_URL/$KEYNAME.asc \\
  | sudo gpg --dearmor -o /etc/apt/keyrings/$KEYNAME.gpg
sudo tee /etc/apt/sources.list.d/spillebulle.sources &gt;/dev/null &lt;&lt;'END'
Types: deb
URIs: $BASE_URL/deb/
Suites: ./
Signed-By: /etc/apt/keyrings/$KEYNAME.gpg
END
sudo apt update</pre>

<h2>Fedora, RHEL, openSUSE</h2>
<pre>sudo rpm --import $BASE_URL/$KEYNAME.asc
sudo tee /etc/yum.repos.d/spillebulle.repo &gt;/dev/null &lt;&lt;'END'
[spillebulle]
name=Spillebulle
baseurl=$BASE_URL/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$BASE_URL/$KEYNAME.asc
END</pre>

<h2>Arch, CachyOS, EndeavourOS, Manjaro</h2>
<pre>curl -fsSL $BASE_URL/$KEYNAME.asc -o /tmp/$KEYNAME.asc
sudo pacman-key --add /tmp/$KEYNAME.asc
sudo pacman-key --lsign-key $key
printf '%s\n' 'SigLevel = Required DatabaseRequired' \\
  'Server = $BASE_URL/arch/\$arch' | sudo tee /etc/pacman.d/spillebulle &gt;/dev/null
printf '\n[spillebulle]\nInclude = /etc/pacman.d/spillebulle\n' | sudo tee -a /etc/pacman.conf &gt;/dev/null
sudo pacman -Sy</pre>

<p>Installing any of the applications from its own <code>.deb</code>,
<code>.rpm</code> or <code>.pkg.tar.zst</code> does all of the above for you. This page is for adding the
archive first and installing from it.</p>

<footer>Built from
<a href="https://github.com/Spillebulle/packages">Spillebulle/packages</a>.
Signed with $key.</footer>
</main>
HTML
} > "$out/index.html"

echo
echo "built into $out:"
find "$out" -maxdepth 2 -type f | sed "s|^$out/|  |" | sort
