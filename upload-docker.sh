#!/bin/bash
# DEPRECATED: images are no longer pushed by hand to Docker Hub.
#
# Releases are built by GitHub Actions (.github/workflows/release.yml) on a
# v* tag and pushed to ghcr.io/p7y-dev/foxglove:<version>-dind / -sysbox.
# To release: bump VERSION, commit, then
#   git tag v<version> && git push origin v<version>
#
# The old csakaszamok/foxglove images on Docker Hub stay as they are.
echo "upload-docker.sh is deprecated: push a v<version> tag; GitHub Actions publishes ghcr.io/p7y-dev/foxglove" >&2
exit 1
