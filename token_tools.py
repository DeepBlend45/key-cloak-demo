from __future__ import annotations

import argparse
import base64
import json
from typing import Any


def decode_jwt_payload(token: str) -> dict[str, Any]:
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("Token is not JWT format")
    payload = parts[1] + ("=" * (-len(parts[1]) % 4))
    return json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))


def validate_basic_claims(
    payload: dict[str, Any], expected_aud: str | None = None, expected_iss: str | None = None
) -> tuple[bool, list[str]]:
    errors: list[str] = []

    if expected_aud:
        aud = payload.get("aud")
        aud_values = aud if isinstance(aud, list) else [aud]
        if expected_aud not in aud_values:
            errors.append(f"aud does not include '{expected_aud}': {aud}")

    if expected_iss and payload.get("iss") != expected_iss:
        errors.append(f"iss mismatch: expected '{expected_iss}', actual '{payload.get('iss')}'")

    return (len(errors) == 0, errors)


def main() -> int:
    parser = argparse.ArgumentParser(description="Decode and validate JWT payload")
    parser.add_argument("--token", required=True)
    parser.add_argument("--expected-aud")
    parser.add_argument("--expected-iss")
    args = parser.parse_args()

    payload = decode_jwt_payload(args.token)
    print(json.dumps(payload, ensure_ascii=False, indent=2))

    ok, errors = validate_basic_claims(payload, args.expected_aud, args.expected_iss)
    if ok:
        print("\nclaims validation: OK")
        return 0

    print("\nclaims validation: NG")
    for e in errors:
        print(f"- {e}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
