#!/usr/bin/env python3
"""Stream stderr while redacting credentials embedded in RPC URLs.

Unlike line-oriented filters, this emits newline-free prompts immediately. Only bytes that may
belong to one of the supported credential forms are held until the form can be classified:

    https://host/v2/<token>
    https://host/v3/<token>
    https://user:password@host
"""

from __future__ import annotations

import os


MARKERS = (b"/v2/", b"/v3/", b"://")
TOKEN_BYTES = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
WHITESPACE_BYTES = frozenset(b" \t\r\n\v\f")


def _write(data: bytes) -> None:
    if data:
        os.write(1, data)


def _partial_marker_length(data: bytes) -> int:
    """Return the longest suffix that could become a marker after the next read."""
    for length in range(min(len(data), max(map(len, MARKERS)) - 1), 0, -1):
        suffix = data[-length:]
        if any(marker.startswith(suffix) for marker in MARKERS):
            return length
    return 0


def _drain(data: bytes, *, eof: bool) -> bytes:
    """Write every classifiable byte and return the still-ambiguous suffix."""
    while data:
        matches = [(index, marker) for marker in MARKERS if (index := data.find(marker)) >= 0]
        if not matches:
            if eof:
                _write(data)
                return b""
            held = _partial_marker_length(data)
            _write(data[:-held] if held else data)
            return data[-held:] if held else b""

        index, marker = min(matches, key=lambda match: match[0])
        _write(data[:index])
        data = data[index + len(marker) :]

        if marker != b"://":
            token_end = 0
            while token_end < len(data) and data[token_end] in TOKEN_BYTES:
                token_end += 1

            if token_end == len(data) and not eof:
                return marker + data

            _write(marker)
            if token_end:
                _write(b"***")
            data = data[token_end:]
            continue

        # A URL authority is basic-auth userinfo only if an '@' arrives before '/', whitespace,
        # or EOF. Hold the authority while it remains ambiguous; ordinary prompts never enter
        # this branch and therefore continue to stream without waiting for a newline.
        authority_end = 0
        while authority_end < len(data):
            byte = data[authority_end]
            if byte == ord("@"):
                _write(b"://***@")
                data = data[authority_end + 1 :]
                break
            if byte == ord("/") or byte in WHITESPACE_BYTES:
                _write(b"://")
                data = data
                break
            authority_end += 1
        else:
            if eof:
                _write(b"://" + data)
                return b""
            return b"://" + data

    return b""


def main() -> None:
    pending = b""
    while chunk := os.read(0, 4096):
        pending = _drain(pending + chunk, eof=False)
    _drain(pending, eof=True)


if __name__ == "__main__":
    main()
