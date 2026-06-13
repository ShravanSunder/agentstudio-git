#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentstudio-git-hosted-artifact.XXXXXX")"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

require_env() {
  local variable_name="$1"
  local description="$2"
  if [ -z "${!variable_name:-}" ]; then
    cat >&2 <<EOF
$variable_name is required for the hosted libgit2 artifact gate.

Set it to $description, then rerun:

  AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="https://<release-host>/CLibGit2Local.xcframework.zip" \\
  AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="<swift-package-checksum>" \\
    bash scripts/verify-hosted-libgit2-artifact.sh
EOF
    exit 2
  fi
}

require_env AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL "the public HTTPS URL for CLibGit2Local.xcframework.zip"
require_env AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM "the SwiftPM checksum for that hosted zip"

binary_url="$AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL"
binary_checksum="$AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM"

host_is_private_or_local_ip() {
  local host="$1"
  perl -MSocket=inet_pton,AF_INET,AF_INET6 -e '
use strict;
use warnings;
my $host = shift // "";

sub blocked_v4 {
    my ($packed) = @_;
    my @bytes = unpack("C4", $packed);
    return 1 if $bytes[0] == 0;
    return 1 if $bytes[0] == 10;
    return 1 if $bytes[0] == 127;
    return 1 if $bytes[0] == 169 && $bytes[1] == 254;
    return 1 if $bytes[0] == 172 && $bytes[1] >= 16 && $bytes[1] <= 31;
    return 1 if $bytes[0] == 192 && $bytes[1] == 168;
    return 0;
}

my $packed4 = inet_pton(AF_INET, $host);
if (defined $packed4) {
    exit(blocked_v4($packed4) ? 0 : 1);
}

my $packed6 = inet_pton(AF_INET6, $host);
if (defined $packed6) {
    my @bytes = unpack("C16", $packed6);
    my $all_zero = 1;
    for my $byte (@bytes) {
        if ($byte != 0) {
            $all_zero = 0;
            last;
        }
    }
    exit 0 if $all_zero;

    my $loopback = 1;
    for my $index (0..14) {
        if ($bytes[$index] != 0) {
            $loopback = 0;
            last;
        }
    }
    exit 0 if $loopback && $bytes[15] == 1;
    exit 0 if (($bytes[0] & 0xfe) == 0xfc);
    exit 0 if ($bytes[0] == 0xfe && (($bytes[1] & 0xc0) == 0x80));

    my $mapped = 1;
    for my $index (0..9) {
        if ($bytes[$index] != 0) {
            $mapped = 0;
            last;
        }
    }
    if ($mapped && $bytes[10] == 0xff && $bytes[11] == 0xff) {
        my $v4 = pack("C4", @bytes[12..15]);
        exit(blocked_v4($v4) ? 0 : 1);
    }
}

exit 1;
' "$host"
}

host_is_known_public_artifact_host() {
  local host="$1"
  case "$host" in
    raw.githubusercontent.com | github.com | objects.githubusercontent.com | github-releases.githubusercontent.com | release-assets.githubusercontent.com)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolved_addresses_for_host() {
  local host="$1"
  if [[ "${AGENTSTUDIO_GIT_TESTING:-}" == "1" &&
    -n "${AGENTSTUDIO_GIT_TEST_RESOLVED_ARTIFACT_ADDRESSES:-}" ]]; then
    printf '%s\n' "$AGENTSTUDIO_GIT_TEST_RESOLVED_ARTIFACT_ADDRESSES"
    return 0
  fi

  perl -MSocket=getaddrinfo,inet_ntop,AF_INET,AF_INET6,SOCK_STREAM,sockaddr_family,unpack_sockaddr_in,unpack_sockaddr_in6 -e '
use strict;
use warnings;
my $host = shift // "";
$SIG{ALRM} = sub { exit 4; };
alarm 5;
my ($error, @results) = getaddrinfo($host, undef, { socktype => SOCK_STREAM });
alarm 0;
exit 3 if $error;
my %seen;
for my $result (@results) {
    my $sockaddr = $result->{addr};
    my $family = sockaddr_family($sockaddr);
    my $address;
    if ($family == AF_INET) {
        my ($port, $packed) = unpack_sockaddr_in($sockaddr);
        $address = inet_ntop(AF_INET, $packed);
    } elsif ($family == AF_INET6) {
        my ($port, $packed) = unpack_sockaddr_in6($sockaddr);
        $address = inet_ntop(AF_INET6, $packed);
    } else {
        next;
    }
    next if $seen{$address}++;
    print "$address\n";
}
' "$host"
}

host_resolves_to_private_or_local_ip() {
  local host="$1"
  local resolved_addresses
  if ! resolved_addresses="$(resolved_addresses_for_host "$host")"; then
    return 0
  fi

  local address
  while IFS= read -r address; do
    [[ -z "$address" ]] && continue
    if host_is_private_or_local_ip "$address"; then
      return 0
    fi
  done <<<"$resolved_addresses"
  return 1
}

if [[ "$binary_url" != https://* ]]; then
  echo "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL must be an https URL for SwiftPM binary target download proof." >&2
  exit 2
fi

if [[ "$binary_url" == *"@"* || "$binary_url" == *"?"* || "$binary_url" == *"#"* || "$binary_url" =~ [[:space:]] ]]; then
  echo "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL must be a public release artifact URL without userinfo, query credentials, fragments, or whitespace." >&2
  exit 2
fi

url_without_scheme="${binary_url#https://}"
host_port="${url_without_scheme%%/*}"
artifact_host_is_ipv6_literal=0
if [[ "$host_port" == \[*\]* ]]; then
  artifact_host="${host_port%%]*}"
  artifact_host="${artifact_host#[}"
  artifact_host_is_ipv6_literal=1
else
  artifact_host="${host_port%%:*}"
fi
artifact_host="$(printf '%s' "$artifact_host" | tr '[:upper:]' '[:lower:]')"
artifact_host_is_private_or_local_ip=0
if host_is_private_or_local_ip "$artifact_host"; then
  artifact_host_is_private_or_local_ip=1
fi
artifact_host_is_known_public_artifact_host=0
if host_is_known_public_artifact_host "$artifact_host"; then
  artifact_host_is_known_public_artifact_host=1
fi
artifact_host_resolves_to_private_or_local_ip=0
if [[ "$artifact_host_is_known_public_artifact_host" -eq 0 ]] &&
  host_resolves_to_private_or_local_ip "$artifact_host"; then
  artifact_host_resolves_to_private_or_local_ip=1
fi

if [[ -z "$artifact_host" ||
  "$artifact_host" == "localhost" ||
  "$artifact_host" == *.localhost ||
  "$artifact_host_is_private_or_local_ip" -eq 1 ||
  "$artifact_host_resolves_to_private_or_local_ip" -eq 1 ]]; then
  echo "AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL must point at a public HTTPS artifact host." >&2
  exit 2
fi

if [[ ! "$binary_checksum" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM must be a 64-character SwiftPM checksum." >&2
  exit 2
fi

mkdir -p "$SCRATCH_DIR/Sources/HostedArtifactConsumer"
mkdir -p "$SCRATCH_DIR/swift-cache" "$SCRATCH_DIR/swift-scratch"

{
  printf '%s\n' '// swift-tools-version: 6.2'
  printf '%s\n' 'import PackageDescription'
  printf '%s\n' ''
  printf '%s\n' 'let package = Package('
  printf '%s\n' '    name: "AgentStudioGitHostedArtifactConsumer",'
  printf '%s\n' '    platforms: ['
  printf '%s\n' '        .macOS(.v14),'
  printf '%s\n' '    ],'
  printf '%s\n' '    products: ['
  printf '%s\n' '        .executable(name: "hosted-artifact-consumer", targets: ["HostedArtifactConsumer"]),'
  printf '%s\n' '    ],'
  printf '%s\n' '    dependencies: ['
  printf '        .package(path: "%s"),\n' "$ROOT_DIR"
  printf '%s\n' '    ],'
  printf '%s\n' '    targets: ['
  printf '%s\n' '        .executableTarget('
  printf '%s\n' '            name: "HostedArtifactConsumer",'
  printf '%s\n' '            dependencies: ['
  printf '%s\n' '                .product(name: "AgentStudioGitLocal", package: "agentstudio-git"),'
  printf '%s\n' '            ]'
  printf '%s\n' '        ),'
  printf '%s\n' '    ]'
  printf '%s\n' ')'
} >"$SCRATCH_DIR/Package.swift"

{
  printf '%s\n' 'import AgentStudioGitLocal'
  printf '%s\n' ''
  printf '%s\n' 'let version = LibGit2ImportCanary.version()'
  printf '%s\n' 'let expectedLibGit2MajorVersion = 1'
  printf '%s\n' 'let expectedLibGit2MinorVersion = 9'
  printf '%s\n' 'let expectedLibGit2RevisionVersion = 4'
  printf '%s\n' 'precondition(version.major == expectedLibGit2MajorVersion)'
  printf '%s\n' 'precondition(version.minor == expectedLibGit2MinorVersion)'
  printf '%s\n' 'precondition(version.revision == expectedLibGit2RevisionVersion)'
  printf '%s\n' 'print("hosted libgit2 \(version.major).\(version.minor).\(version.revision)")'
} >"$SCRATCH_DIR/Sources/HostedArtifactConsumer/main.swift"

echo "--- hosted libgit2 artifact proof ---"
echo "artifact: configured HTTPS URL (value not printed)"
echo "checksum: configured SwiftPM checksum"

swift_output="$SCRATCH_DIR/swift-output.txt"
if AGENTSTUDIO_GIT_LIBGIT2_BINARY_URL="$binary_url" \
  AGENTSTUDIO_GIT_LIBGIT2_BINARY_CHECKSUM="$binary_checksum" \
  swift run \
    --package-path "$SCRATCH_DIR" \
    --cache-path "$SCRATCH_DIR/swift-cache" \
    --scratch-path "$SCRATCH_DIR/swift-scratch" \
    --manifest-cache local \
    hosted-artifact-consumer >"$swift_output" 2>&1; then
  echo "hosted libgit2 artifact linked successfully"
else
  status="$?"
  echo "hosted libgit2 artifact verification failed; SwiftPM output omitted to avoid artifact URL disclosure." >&2
  exit "$status"
fi
