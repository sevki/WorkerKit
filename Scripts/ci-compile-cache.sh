#!/usr/bin/env bash
# Makes the rest of a CI job compile through llbuild-worker's live cache
# (https://xcache.devtoo.ls) - the same cache that repo's own CI validates
# itself against, here validating a real multi-target Swift package build
# instead of a synthetic one.
#
# Downloads the latest *released* CASPlugin from sevki/llbuild-worker (the
# artifact users install, not a build of this checkout) and exports
# SWIFT_CACHE_FLAGS for later steps:
#
#   swift test ${SWIFT_CACHE_FLAGS:+--build-system native $SWIFT_CACHE_FLAGS}
#
# The job must have the cache's access token in LLBUILD_CAS_TOKEN, and
# should set LLBUILD_CAS_REMOTE_URL to its own scope (a Worker path segment,
# e.g. https://xcache.devtoo.ls/ci-workerkit-linux) so this job's own
# compile churn never lands in production's default scope alongside real
# users, or in llbuild-worker's own CI lanes.
#
# Best effort, like the plugin itself: with no token (a pull request from a
# fork gets no secrets), an unsupported runner, or no release to download,
# it leaves SWIFT_CACHE_FLAGS unset and the job builds without the cache.
set -euo pipefail

: "${GITHUB_ENV:?run this from a GitHub Actions step}"
: "${RUNNER_TEMP:?run this from a GitHub Actions step}"
remote="${LLBUILD_CAS_REMOTE_URL:-https://xcache.devtoo.ls}"
# `all` shares every result with the Worker, including those a compiler marks
# local-only (Apple's Swift 6.3 swiftc marks all of them, so on macOS
# nothing would travel otherwise). A plugin release without the option
# stores and ignores it, so this is safe to pass regardless of version.
scope="${LLBUILD_CAS_REMOTE_SCOPE:-all}"

if [ -z "${LLBUILD_CAS_TOKEN:-}" ]; then
    echo "::notice::No XCACHE_TOKEN (a pull request from a fork?): building without the compile cache"
    exit 0
fi

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) asset=CASPlugin-linux-x86_64; lib=libCASPlugin.so ;;
    Darwin-arm64) asset=CASPlugin-macos-arm64; lib=libCASPlugin.dylib ;;
    *)
        echo "::notice::No released CASPlugin for $(uname -s) $(uname -m): building without the compile cache"
        exit 0
        ;;
esac

dir="$RUNNER_TEMP/cas-plugin"
mkdir -p "$dir"
if ! curl -fsSL "https://github.com/sevki/llbuild-worker/releases/latest/download/$asset.tar.gz" \
        | tar -xz -C "$dir" || [ ! -f "$dir/$lib" ]; then
    echo "::warning::Could not download $asset from llbuild-worker's latest release: building without the compile cache"
    exit 0
fi

# -explicit-module-build is what makes compile jobs cacheable; -Rcache-compile-job
# leaves a hit or miss line per compile in the log.
flags=(
    -Xswiftc -cache-compile-job
    -Xswiftc -explicit-module-build
    -Xswiftc -cas-path -Xswiftc "$RUNNER_TEMP/cas"
    -Xswiftc -cas-plugin-path -Xswiftc "$dir/$lib"
    -Xswiftc -cas-plugin-option -Xswiftc "remote-url=$remote"
    -Xswiftc -cas-plugin-option -Xswiftc "remote-scope=$scope"
    -Xswiftc -Rcache-compile-job
)
echo "SWIFT_CACHE_FLAGS=${flags[*]}" >> "$GITHUB_ENV"
echo "Compiling Swift through $remote with $dir/$lib"
