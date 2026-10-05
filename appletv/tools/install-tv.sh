#!/bin/zsh
# Build Altitude++ and install it on an Apple TV paired with this Mac.
# Run with --help for options. The work is done by install_tv.py.
exec /usr/bin/env python3 "${0:A:h}/install_tv.py" "$@"
