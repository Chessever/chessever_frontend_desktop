#!/usr/bin/env python3
"""Unlock only the configured release keychain, without GUI or password argv."""

import ctypes
from pathlib import Path
import sys


def main():
    keychain_path = sys.argv[1]
    password_file = sys.argv[2] if len(sys.argv) > 2 else ""
    security = ctypes.CDLL(
        "/System/Library/Frameworks/Security.framework/Security"
    )
    security.SecKeychainSetUserInteractionAllowed.argtypes = [ctypes.c_bool]
    security.SecKeychainSetUserInteractionAllowed(False)
    security.SecKeychainOpen.argtypes = [
        ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)
    ]
    security.SecKeychainOpen.restype = ctypes.c_int32
    security.SecKeychainGetStatus.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)
    ]
    security.SecKeychainGetStatus.restype = ctypes.c_int32
    security.SecKeychainUnlock.argtypes = [
        ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_bool
    ]
    security.SecKeychainUnlock.restype = ctypes.c_int32

    keychain = ctypes.c_void_p()
    status = security.SecKeychainOpen(keychain_path.encode(), ctypes.byref(keychain))
    if status:
        raise SystemExit(f"Cannot open release keychain (OSStatus {status}).")
    flags = ctypes.c_uint32()
    status = security.SecKeychainGetStatus(keychain, ctypes.byref(flags))
    if status:
        raise SystemExit(f"Cannot inspect release keychain (OSStatus {status}).")
    if flags.value & 1:
        return
    if not password_file:
        raise SystemExit(
            "Release keychain is locked. Set STORE_KEYCHAIN_PASSWORD_FILE "
            "to its private local password file before building."
        )
    password = Path(password_file).read_bytes().rstrip(b"\r\n")
    buffer = ctypes.create_string_buffer(password)
    try:
        status = security.SecKeychainUnlock(keychain, len(password), buffer, True)
    finally:
        ctypes.memset(buffer, 0, len(buffer))
        del password
    if status:
        raise SystemExit(f"Release keychain unlock failed (OSStatus {status}).")


if __name__ == "__main__":
    main()
