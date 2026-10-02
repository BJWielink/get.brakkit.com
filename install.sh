#!/bin/sh
# deployer bootstrap installer (llm/07-packaging-and-updates.md §4.2).
#
#   curl -fsSL https://get.brakkit.com/install.sh | sudo sh
#   curl -fsSL https://get.brakkit.com/install.sh | sudo sh -s -- --channel beta
#   sudo sh install.sh --deb ./deployer_0.1.0-1+deb13_amd64.deb      # local package, no repository
#   sudo sh install.sh --domain deploy.example.com --non-interactive
#
# It does exactly the documented manual steps and nothing else, so it can be audited:
#   1. preflight: Debian 13, amd64, root, systemd, no competing web server (--force);
#   2. the nginx.org signing keys (embedded below, SHA-256 and fingerprints checked), the
#      nginx.org repository and the apt pins that keep nginx on nginx.org's 1.30 branch;
#   3. deployer's signing key (embedded below, SHA-256 and fingerprint checked) and repository
#      https://get.brakkit.com, suite trixie (stable) or trixie-beta (--channel beta);
#      skipped with --deb, which installs that file instead;
#   4. apt-get install deployer;
#   5. hand over to `deployer setup`.
# Every step is idempotent: running the script again repairs or upgrades an installation.
# Nothing runs before the last line, so a truncated download cannot run half a script.

set -eu

# --- pinned values -----------------------------------------------------------------------------

# /usr/share/keyrings/nginx-archive-keyring.gpg: `gpg --dearmor` of
# https://nginx.org/keys/nginx_signing.key as fetched on 2026-10-01 (llm/02-nginx.md §1.3).
NGINX_KEYRING=/usr/share/keyrings/nginx-archive-keyring.gpg
NGINX_KEYRING_SHA256=7d3d5a7adf37e17d6882e2f6f55324b9a8f978ef3c99c50fe801af67c9847c91
# nginx.org's documented key (573B…) plus the two newer keys in the same file; trixie's
# InRelease is signed by 8540A6F1… (checked 2026-10-01).
NGINX_FINGERPRINTS="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 8540A6F18833A80E9C1653A42FD21310B49F6B46 9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3"

# deployer's own apt repository (llm/07 §11, llm/09-release.md). The keyring is
# packaging/keyrings/deployer-archive-keyring.pgp, embedded by dev/release/embed-keyring.sh; the
# package ships the same file, so later key rotations arrive as normal updates.
DEPLOYER_REPO_URI=https://get.brakkit.com
DEPLOYER_KEYRING=/usr/share/keyrings/deployer-archive-keyring.pgp
DEPLOYER_KEYRING_SHA256=695b0138c17bfa9707d4b9d7d4ef6d44487c877431d3e602f76e95bb748a8fa6
DEPLOYER_FINGERPRINT="357C9B7EEE026287976A6D7FB4D6AAE597BF45B1"
# Removed by the package's postrm (llm/07 §10).
DEPLOYER_SOURCES=/etc/apt/sources.list.d/deployer.sources

APT_OPTS="-o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# --- helpers -----------------------------------------------------------------------------------

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: install.sh [options]

  --channel C         release channel: stable (default) or beta
  --deb PATH          install deployer from this .deb instead of the repository (no updates
                      from the repository until install.sh runs again without --deb)
  --domain NAME       domain of the web UI, passed to `deployer setup`
  --non-interactive   never prompt (also --yes, -y); runs `deployer setup --non-interactive`
  --no-setup          install only; run `deployer setup` yourself later
  --force             skip the "no other web server" checks
  -h, --help          this help

Testing only: --repo-url URL (or DEPLOYER_REPO_URL) replaces https://get.brakkit.com; the
signature is still checked against the embedded key.
EOF
}

# Writes stdin to $1 with mode $2, atomically (temp file in the same directory, then rename).
write_file() {
    tmp="$1.tmp.$$"
    cat >"$tmp"
    chmod "$2" "$tmp"
    mv -f "$tmp" "$1"
}

pkg_installed() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

pkg_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

# nginx from nginx.org is versioned like 1.30.5-1~trixie; Debian's is 1.26.3-3+deb13u9.
nginx_is_from_nginx_org() {
    case "$(pkg_version nginx)" in
        *~trixie) return 0 ;;
        *) return 1 ;;
    esac
}

# Prints the local TCP ports in LISTEN state, in hex as /proc/net/tcp shows them.
listening_ports() {
    cat /proc/net/tcp /proc/net/tcp6 2>/dev/null |
        awk 'NR > 1 && $4 == "0A" { n = split($2, a, ":"); print a[n] }' | sort -u
}

# --- steps -------------------------------------------------------------------------------------

preflight() {
    step "Preflight"
    [ "$(id -u)" -eq 0 ] || die "run as root (sudo sh install.sh …)"

    codename=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null | tr -d '"')
    [ "$codename" = trixie ] || die "deployer supports only Debian 13 (trixie); this is '${codename:-unknown}'"

    arch=$(dpkg --print-architecture)
    [ "$arch" = amd64 ] || die "unsupported architecture $arch (amd64 only)"

    [ -d /run/systemd/system ] || die "systemd is not running as PID 1"

    if [ -n "$deb" ]; then
        [ -f "$deb" ] || die "--deb $deb: no such file"
        deb_arch=$(dpkg-deb -f "$deb" Architecture) || die "--deb $deb is not a .deb"
        deb_name=$(dpkg-deb -f "$deb" Package)
        [ "$deb_name" = deployer ] || die "--deb $deb contains package '$deb_name', not deployer"
        [ "$deb_arch" = "$arch" ] || die "--deb $deb is for $deb_arch, this machine is $arch"
    fi
    say "Debian 13 (trixie), $arch, root, systemd: ok"

    if [ "$force" = 1 ]; then
        say "--force: skipping the web server checks"
        return 0
    fi
    for p in apache2 caddy lighttpd docker-ce docker.io nginx-common nginx-core nginx-full nginx-light nginx-extras; do
        if pkg_installed "$p"; then
            die "package $p is installed; deployer needs a fresh server (or use --force)"
        fi
    done
    if pkg_installed nginx && ! nginx_is_from_nginx_org; then
        die "Debian's nginx $(pkg_version nginx) is installed; deployer uses nginx.org's (or use --force)"
    fi
    if command -v docker >/dev/null 2>&1; then
        die "docker is installed; deployer needs a fresh server (or use --force)"
    fi
    # Ports 80 (0050) and 443 (01BB): only nginx.org's nginx (an earlier run) may hold them.
    if listening_ports | grep -qx -e 0050 -e 01BB; then
        if pkg_installed nginx && nginx_is_from_nginx_org; then
            say "ports 80/443 are held by nginx.org's nginx (earlier installation): ok"
        else
            die "something already listens on port 80 or 443 (or use --force)"
        fi
    else
        say "no other web server, ports 80/443 free: ok"
    fi
}

# Writes the keyring that function $1 prints (base64) to $2 after checking its SHA-256 ($3) and,
# when gpg is present, that it holds the primary keys $4. $5 names it in messages.
install_keyring() {
    tmp=$(mktemp)
    "$1" | base64 -d >"$tmp"
    sum=$(sha256sum "$tmp" | cut -d ' ' -f 1)
    if [ "$sum" != "$3" ]; then
        rm -f "$tmp"
        die "the embedded $5 keyring does not match its SHA-256; the script is damaged"
    fi
    if command -v gpg >/dev/null 2>&1; then
        gnupghome=$(mktemp -d)
        fprs=$(GNUPGHOME=$gnupghome gpg --batch --show-keys --with-colons "$tmp" 2>/dev/null |
            awk -F: '$1 == "fpr" { print $10 }')
        rm -rf "$gnupghome"
        for f in $4; do
            if ! printf '%s\n' "$fprs" | grep -qx "$f"; then
                rm -f "$tmp"
                die "$5 key $f is missing from the embedded keyring"
            fi
        done
        say "$5 signing keys verified: $4"
    else
        say "$5 keyring verified by SHA-256 (keys $4; install gpg to re-check the fingerprints)"
    fi
    chmod 0644 "$tmp"
    mv -f "$tmp" "$2"
}

install_nginx_repo() {
    step "nginx.org repository"
    install_keyring nginx_keyring_b64 "$NGINX_KEYRING" "$NGINX_KEYRING_SHA256" "$NGINX_FINGERPRINTS" nginx.org

    write_file /etc/apt/sources.list.d/nginx.sources 0644 <<EOF
# Written by deployer's install.sh (llm/02-nginx.md §1.3); kept when deployer is removed so that
# nginx keeps receiving updates.
Types: deb
URIs: https://nginx.org/packages/debian
Suites: trixie
Components: nginx
Signed-By: $NGINX_KEYRING
EOF

    write_file /etc/apt/preferences.d/90-nginx-org 0644 <<'EOF'
# Written by deployer's install.sh (llm/02-nginx.md §1.3); kept when deployer is removed.
# 2. Prefer nginx.org over anything else.
Package: nginx nginx-dbg nginx-module-*
Pin: release o=nginx
Pin-Priority: 900

# 3. Never let Debian's nginx (or modules built against it) in.
Package: nginx nginx-common nginx-core nginx-full nginx-light nginx-extras libnginx-mod-*
Pin: release o=Debian
Pin-Priority: -1
EOF

    # Taken over by the package (`deployer internal postinst`) and removed with it.
    write_file /etc/apt/preferences.d/85-deployer-nginx-branch 0644 <<'EOF'
# Generated by deployer (llm/02-nginx.md §1.3); removed when deployer is removed.
# Stay on the nginx.org stable branch this deployer release was tested against.
Package: nginx nginx-dbg nginx-module-*
Pin: version 1.30.*
Pin-Priority: 990
EOF
    say "nginx.sources, 90-nginx-org and 85-deployer-nginx-branch written"
}

install_deployer_repo() {
    step "deployer repository"
    case "$channel" in
        stable) suite=trixie ;;
        beta) suite=trixie-beta ;;
        *) die "--channel must be stable or beta, not '$channel'" ;;
    esac
    if [ "$repo_uri" != "$DEPLOYER_REPO_URI" ]; then
        say "TESTING ONLY: repository $repo_uri instead of $DEPLOYER_REPO_URI (signature still checked)"
    fi
    # The package ships the same file and owns it after the installation: an installed package's
    # keyring may be newer (key rotation) than the one in this script, so it is kept.
    if pkg_installed deployer && [ -s "$DEPLOYER_KEYRING" ]; then
        say "keyring $DEPLOYER_KEYRING belongs to the installed deployer package: kept"
    else
        install_keyring deployer_keyring_b64 "$DEPLOYER_KEYRING" "$DEPLOYER_KEYRING_SHA256" \
            "$DEPLOYER_FINGERPRINT" deployer
    fi
    write_file "$DEPLOYER_SOURCES" 0644 <<EOF
# Written by deployer's install.sh (llm/09-release.md); removed when deployer is removed.
# Channel: Suites trixie = stable, trixie-beta = beta (or run install.sh --channel … again).
Types: deb
URIs: $repo_uri
Suites: $suite
Components: main
Architectures: amd64
Signed-By: $DEPLOYER_KEYRING
EOF
    say "$DEPLOYER_SOURCES written: $repo_uri $suite ($channel channel)"
}

install_packages() {
    step "Installing packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    policy=$(apt-cache policy nginx)
    candidate=$(printf '%s\n' "$policy" | sed -n 's/^ *Candidate: //p')
    case "$candidate" in
        1.30.*~trixie) ;;
        *) die "apt would install nginx '$candidate'; expected nginx.org's 1.30.x (check the pins in /etc/apt/preferences.d)" ;;
    esac
    printf '%s\n' "$policy" | grep -q 'nginx.org/packages/debian trixie/nginx' ||
        die "the nginx.org repository is missing from 'apt-cache policy nginx'"
    say "nginx candidate $candidate from nginx.org: ok"
    if [ -n "$deb" ]; then
        # shellcheck disable=SC2086 # APT_OPTS is a list of options
        apt-get install -y -q --no-install-recommends $APT_OPTS "$deb" needrestart
        # The self-update needs the installed version's package for its automatic rollback
        # (llm/07 §8.3); a repository install downloads it, a file install keeps it here.
        rollback=/var/lib/deployer/rollback
        mkdir -p "$rollback"
        chmod 0700 "$rollback"
        cp -f "$deb" "$rollback/deployer_$(pkg_version deployer)_$(dpkg --print-architecture).deb"
    else
        candidate=$(apt-cache policy deployer | sed -n 's/^ *Candidate: //p')
        case "$candidate" in
            '' | '(none)') die "the deployer repository offers no deployer package for the $channel channel" ;;
        esac
        say "deployer candidate $candidate from $repo_uri: ok"
        # shellcheck disable=SC2086 # APT_OPTS is a list of options
        apt-get install -y -q --no-install-recommends $APT_OPTS deployer needrestart
    fi
    say "installed: deployer $(pkg_version deployer), nginx $(pkg_version nginx), podman $(pkg_version podman)"
}

hand_over() {
    if [ "$no_setup" = 1 ]; then
        step "Done. Next: sudo deployer setup"
        return 0
    fi
    step "deployer setup"
    if [ "$non_interactive" = 1 ]; then
        if [ -n "$domain" ]; then
            exec deployer setup --non-interactive --domain "$domain"
        fi
        exec deployer setup --non-interactive
    fi
    # Piped through `curl | sh`, stdin is the script: talk to the terminal directly.
    if [ -t 1 ] && (: </dev/tty) 2>/dev/null; then
        if [ -n "$domain" ]; then
            exec deployer setup --domain "$domain" </dev/tty
        fi
        exec deployer setup </dev/tty
    fi
    say "No terminal available. Run: sudo deployer setup"
}

# --- embedded keyrings -------------------------------------------------------------------------

nginx_keyring_b64() {
    cat <<'EOF'
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
EOF
}

# packaging/keyrings/deployer-archive-keyring.pgp (written by dev/release/embed-keyring.sh).
deployer_keyring_b64() {
    cat <<'EOF'
mDMEar+qyxYJKwYBBAHaRw8BAQdASK1MuSB2qbU3iNIdiobUPgv5d2Q/QispmGda5uY4GOW0LmRl
cGxveWVyIGFyY2hpdmUgc2lnbmluZyBrZXkgKGdldC5icmFra2l0LmNvbSmIjgQTFgoANhYhBDV8
m37uAmKHl2ptf7TWquWXv0WxBQJqv6rLAhsBBAsJCAcEFQoJCAUWAgMBAAIeAQIXgAAKCRC01qrl
l79FscrRAP4v4HqpjOD3sC//KgZoex9rR9XfH2Xc1RRwBYQWZxfsKwD/TOUd3RJZE0E4wDm34Kjc
qJ+qSgcYZ5/ilKxm+a/iqQG4MwRqv6rLFgkrBgEEAdpHDwEBB0DwXv09rkwrzWsPgKmApUHCIE/F
lLrAsg1yYVAtdNtyFYj1BBgWCgAmFiEENXybfu4CYoeXam1/tNaq5Ze/RbEFAmq/qssCGwIFCQlm
AYAAgQkQtNaq5Ze/RbF2IAQZFgoAHRYhBIMJwmYnZ4KdrfA8oqcK6jjThzfuBQJqv6rLAAoJEKcK
6jjThzfuzAEA/3PqlVqJk54B6Dg0BWjYH1HSyMEPNWze3nlcLwOp7/taAP9+SvFZa47sCRi7Q17r
1xtRm3JfkivJsZcl6LSq8EKHASKlAQCP+hfyIg5L84tjVjBeyNaQOO3lw3a/bEHwp+gcjfK+bAD+
MVtNNrj2iGj8iFwGTKXJX474WPw4H7ZgUwKNpHc2kA0=
EOF
}

# --- main --------------------------------------------------------------------------------------

main() {
    deb=
    domain=
    non_interactive=0
    no_setup=0
    force=0
    channel=stable
    repo_uri=${DEPLOYER_REPO_URL:-$DEPLOYER_REPO_URI}
    while [ $# -gt 0 ]; do
        case "$1" in
            --channel)
                [ $# -ge 2 ] || die "--channel needs stable or beta"
                channel=$2
                shift 2
                ;;
            --channel=*)
                channel=${1#--channel=}
                shift
                ;;
            --repo-url)
                [ $# -ge 2 ] || die "--repo-url needs a URL"
                repo_uri=$2
                shift 2
                ;;
            --repo-url=*)
                repo_uri=${1#--repo-url=}
                shift
                ;;
            --deb)
                [ $# -ge 2 ] || die "--deb needs a path"
                deb=$2
                shift 2
                ;;
            --deb=*)
                deb=${1#--deb=}
                shift
                ;;
            --domain)
                [ $# -ge 2 ] || die "--domain needs a name"
                domain=$2
                shift 2
                ;;
            --domain=*)
                domain=${1#--domain=}
                shift
                ;;
            --non-interactive | --yes | -y)
                non_interactive=1
                shift
                ;;
            --no-setup)
                no_setup=1
                shift
                ;;
            --force)
                force=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "unknown option: $1"
                ;;
        esac
    done
    case "$channel" in
        stable | beta) ;;
        *) die "--channel must be stable or beta, not '$channel'" ;;
    esac
    case "$repo_uri" in
        *[!A-Za-z0-9:/._~%@+-]*) die "--repo-url contains characters a URL here never needs: '$repo_uri'" ;;
        https://* | http://*) ;;
        *) die "--repo-url must be an http(s) URL, not '$repo_uri'" ;;
    esac
    repo_uri=${repo_uri%/}
    if [ -n "$deb" ]; then
        # apt-get installs a local file only when given as a path.
        case "$deb" in
            /*) ;;
            *) deb="$(pwd)/$deb" ;;
        esac
    fi

    preflight
    install_nginx_repo
    if [ -z "$deb" ]; then
        install_deployer_repo
    fi
    install_packages
    hand_over
}

main "$@"
