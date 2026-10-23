"""Offline candidate for Station Max. Does not connect to or change the Station.

Patch a fresh genuine get_sync_info response by changing only two existing
platform booleans. Full responses may contain secrets: never print them.
Runtime applicability on firmware 3.364.25 is not yet verified.
"""
import copy
import json

PLATFORM = "com.yandex.tv.services.platform"
FLAGS = ("adbEnabled", "developmentSettingsEnabled")


def patch_payload(body):
    original = json.loads(body)
    if not isinstance(original, dict):
        raise ValueError("Response is not an object")
    if original.get("status") != "ok":
        raise ValueError("Upstream response is not successful")
    try:
        platform = original["config"]["system_config"][PLATFORM]
    except (KeyError, TypeError):
        raise ValueError("Expected Max platform section is absent") from None
    if not isinstance(platform, dict):
        raise ValueError("Platform section is not an object")
    if any(type(platform.get(name)) is not bool for name in FLAGS):
        raise ValueError("Expected existing boolean flags are absent")

    modified = copy.deepcopy(original)
    target = modified["config"]["system_config"][PLATFORM]
    changed = []
    for name in FLAGS:
        if target[name] is False:
            changed.append(["config", "system_config", PLATFORM, name])
        target[name] = True

    # Reversing only these two edits must reproduce the complete original.
    restored = copy.deepcopy(modified)
    for name in FLAGS:
        restored["config"]["system_config"][PLATFORM][name] = platform[name]
    if restored != original:
        raise ValueError("Unexpected modification outside the two flags")
    result = json.dumps(modified, ensure_ascii=False, separators=(",", ":")).encode()
    return result, changed
