# libgit2

Pinned source:

- Repository: https://github.com/libgit2/libgit2
- Tag: `v1.9.4`
- Commit: `f7164261c9bc0a7e0ebf767c584e5192810a8b24`

License:

- `GPL-2.0-only WITH GCC-exception-2.0`
- Upstream license file: `vendor/libgit2/COPYING`

Build profile:

```bash
cmake -S vendor/libgit2 -B .build/libgit2/macos-universal \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTS=OFF \
  -DBUILD_CLI=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_BENCHMARKS=OFF \
  -DBUILD_FUZZERS=OFF \
  -DUSE_SSH=OFF \
  -DUSE_HTTP=OFF \
  -DUSE_HTTPS=OFF \
  -DUSE_AUTH_NEGOTIATE=OFF \
  -DUSE_GSSAPI=OFF
```

Remote/auth note:

- This package intentionally builds local libgit2 without SSH, HTTP, HTTPS, or negotiate-auth transport support.
- Authenticated clone, fetch, push, and remote reference discovery are handled by the system-Git-backed remote seam so the user's credential helpers, SSH agent, certificates, Git config, and enterprise setup remain authoritative.

Update process:

1. Choose the next accepted libgit2 tag.
2. Update `vendor/libgit2` to the exact commit for that tag.
3. Update this file's tag and commit.
4. Run `mise run build-libgit2`.
5. Run `mise run verify-libgit2`.
6. Run `swift test`.
7. Run `bash scripts/verify-package-consumer.sh`.
