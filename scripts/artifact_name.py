"""File names used by this edition's packaging scripts."""

import re


def release_version(tag):
    match = re.fullmatch(r"v?(\d+\.\d+\.\d+)(?:[-_.][A-Za-z0-9][A-Za-z0-9._-]*)?", tag)
    if match is None:
        raise ValueError("release tag must be a version, such as 1.0.0 or v1.0.0_nightly")
    return match.group(1)


def artifact_name(info, edition):
    tag = info.get("TossReleaseTag")
    if tag is None:
        label = f"Build {info['CFBundleVersion']}"
    else:
        release_version(tag)
        label = tag
    return f"Toss {label} for {edition}"
