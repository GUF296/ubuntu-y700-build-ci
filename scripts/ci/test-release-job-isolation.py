#!/usr/bin/env python3
"""Keep untrusted rootfs construction separate from release publication."""

from __future__ import annotations

import copy
import pathlib
import re
import sys

import yaml


class WorkflowLoader(yaml.SafeLoader):
    pass


# GitHub treats "on" as a string; YAML 1.1 loaders otherwise coerce it to True.
for first, resolvers in list(WorkflowLoader.yaml_implicit_resolvers.items()):
    WorkflowLoader.yaml_implicit_resolvers[first] = [
        item for item in resolvers if item[0] != "tag:yaml.org,2002:bool"
    ]


CHECKOUT = "actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5"
UPLOAD = "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"
DOWNLOAD = "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093"
ARTIFACT_NAME = "release-staging-" + "$" + "{{ github.run_id }}-" + "$" + "{{ github.run_attempt }}"
RELEASE_GUARD = "$" + "{{ inputs.release_tag != '' }}"
EXACT_SHA = "$" + "{{ github.sha }}"
GITHUB_TOKEN = "$" + "{{ github.token }}"
PINNED_ACTION = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$")


def fail(message: str) -> None:
    raise SystemExit(f"release job isolation check failed: {message}")


def mapping(value: object, label: str) -> dict:
    if not isinstance(value, dict):
        fail(f"{label} must be a mapping")
    return value


def steps_for(job: dict, label: str) -> list[dict]:
    steps = job.get("steps")
    if not isinstance(steps, list) or not steps:
        fail(f"{label}.steps must be a non-empty list")
    result: list[dict] = []
    for index, step in enumerate(steps):
        result.append(mapping(step, f"{label}.steps[{index}]"))
    return result


def named_step(steps: list[dict], name: str) -> dict:
    matches = [step for step in steps if step.get("name") == name]
    if len(matches) != 1:
        fail(f"expected exactly one step named {name!r}, found {len(matches)}")
    return matches[0]


def require_pinned_action(step: dict, expected: str, label: str) -> None:
    uses = step.get("uses")
    if uses != expected:
        fail(f"{label} must use {expected}, found {uses!r}")
    if not PINNED_ACTION.fullmatch(str(uses)):
        fail(f"{label} does not use an immutable action commit")


def scalar_text(value: object):
    if isinstance(value, dict):
        for key, child in value.items():
            if isinstance(key, str):
                yield key
            yield from scalar_text(child)
    elif isinstance(value, list):
        for child in value:
            yield from scalar_text(child)
    elif isinstance(value, str):
        yield value


def check_release_guard(step: dict, label: str) -> None:
    if step.get("if") != RELEASE_GUARD:
        fail(f"{label} must be guarded by a non-empty release_tag")


def validate(data: dict) -> None:
    jobs = mapping(data.get("jobs"), "jobs")
    build = mapping(jobs.get("build"), "jobs.build")
    publish = mapping(jobs.get("publish"), "jobs.publish")

    if build.get("permissions") != {"contents": "read"}:
        fail("build job must retain only contents: read")
    for value in scalar_text(build):
        if "RELEASE_TOKEN" in value or "GH_TOKEN" in value or "github.token" in value:
            fail("build job references a release credential")
    if "publish-release.sh" in "\n".join(scalar_text(build)):
        fail("build job invokes the release publisher")

    build_steps = steps_for(build, "jobs.build")
    staging = named_step(build_steps, "Upload release assets")
    check_release_guard(staging, "release asset staging")
    staging_run = staging.get("run")
    if not isinstance(staging_run, str):
        fail("release asset staging must have a shell body")
    for token in (
        "release_stage=out/ci-release/release-staging",
        'release_dir="$release_stage/assets"',
        'notes="$release_dir/BUILD-PARAMETERS.md"',
        "stage_release_file() {",
        '[ ! -L "$source" ] || {',
        'bash scripts/ci/validate-release-staging.sh "$release_stage"',
        'bash scripts/ci/write-release-manifest.sh "$release_stage"',
    ):
        if token not in staging_run:
            fail(f"release asset staging is missing {token!r}")
    if staging_run.count('bash scripts/ci/validate-release-staging.sh "$release_stage"') != 2:
        fail("release asset staging must validate before and after manifest generation")

    staged_upload = named_step(build_steps, "Upload staged release payload")
    check_release_guard(staged_upload, "staged release artifact upload")
    if build_steps.index(staging) >= build_steps.index(staged_upload):
        fail("release staging must complete before its artifact is uploaded")
    require_pinned_action(staged_upload, UPLOAD, "staged release artifact upload")
    staged_upload_with = mapping(
        staged_upload.get("with"), "staged release artifact upload.with"
    )
    if staged_upload_with.get("name") != ARTIFACT_NAME:
        fail("staged release artifact has an unexpected name")
    if staged_upload_with.get("path") != "out/ci-release/release-staging":
        fail("staged release artifact does not contain the isolated staging directory")
    if staged_upload_with.get("if-no-files-found") != "error":
        fail("staged release artifact must fail closed when staging is absent")

    if publish.get("needs") != "build":
        fail("publish job must depend directly on build")
    check_release_guard(publish, "publish job")
    if publish.get("permissions") != {"contents": "write"}:
        fail("publish job must receive only contents: write")
    if any("RELEASE_TOKEN" in value for value in scalar_text(data)):
        fail("workflow must not reference RELEASE_TOKEN")
    publish_job_env = publish.get("env")
    if publish_job_env is not None:
        publish_job_env_text = "\n".join(
            scalar_text(mapping(publish_job_env, "jobs.publish.env"))
        )
        if (
            "RELEASE_TOKEN" in publish_job_env_text
            or "GH_TOKEN" in publish_job_env_text
            or "github.token" in publish_job_env_text
        ):
            fail("publish job-level environment exposes a release credential")

    publish_steps = steps_for(publish, "jobs.publish")
    checkout = named_step(publish_steps, "Checkout exact release source")
    require_pinned_action(checkout, CHECKOUT, "publish checkout")
    checkout_with = mapping(checkout.get("with"), "publish checkout.with")
    if checkout_with.get("ref") != EXACT_SHA:
        fail("publish checkout must use github.sha exactly")
    if str(checkout_with.get("persist-credentials", "")).lower() != "false":
        fail("publish checkout must disable persisted credentials")

    downloads = [
        step
        for step in publish_steps
        if isinstance(step.get("uses"), str)
        and step["uses"].startswith("actions/download-artifact@")
    ]
    if len(downloads) != 1:
        fail("publish job must download exactly one artifact")
    download = named_step(publish_steps, "Download staged release payload")
    if downloads[0] is not download:
        fail("publish job downloads an artifact other than the staged release payload")
    if publish_steps.index(checkout) >= publish_steps.index(download):
        fail("publish checkout must precede staged artifact download")
    require_pinned_action(download, DOWNLOAD, "staged release artifact download")
    download_with = mapping(download.get("with"), "staged release artifact download.with")
    if download_with != {"name": ARTIFACT_NAME, "path": "release-staging"}:
        fail("publish job must download only the staged release artifact")

    publisher = named_step(publish_steps, "Create verified prerelease draft")
    if publisher is not publish_steps[-1]:
        fail("publisher must be the final publish job step")
    if publish_steps.index(download) >= publish_steps.index(publisher):
        fail("staged artifact download must precede publication")
    publisher_env = mapping(publisher.get("env"), "publisher env")
    if publisher_env.get("GH_TOKEN") != GITHUB_TOKEN:
        fail("only the final publisher step may receive github.token as GH_TOKEN")
    if publisher_env.get("RELEASE_TAG") != "$" + "{{ inputs.release_tag }}":
        fail("publisher must receive the requested release tag")
    if publisher_env.get("PRERELEASE") != "$" + "{{ inputs.prerelease && '1' || '0' }}":
        fail("publisher must receive the prerelease mode")

    for step in publish_steps:
        uses = step.get("uses")
        if uses is not None and uses not in (CHECKOUT, DOWNLOAD):
            fail("publish job must not invoke an action beyond checkout and download")
        env = step.get("env")
        if step is not publisher and isinstance(env, dict) and "GH_TOKEN" in env:
            fail("a non-publisher publish step receives GH_TOKEN")
        if step is not publisher:
            step_text = "\n".join(scalar_text(step))
            if "GH_TOKEN" in step_text or "github.token" in step_text:
                fail("a non-publisher publish step references a release credential")
        run = step.get("run")
        if isinstance(run, str) and re.search(
            r"\b(?:sudo|chroot|debootstrap|apt-get)\b|scripts/ci/build[-a-z]*\.sh",
            run,
        ):
            fail("publish job must not construct a rootfs or enter a privileged environment")
    publisher_run = publisher.get("run")
    if not isinstance(publisher_run, str):
        fail("publisher step must have a shell body")
    for token in (
        '[ "$(git rev-parse HEAD)" = "$GITHUB_SHA" ]',
        "release_stage=$(pwd -P)/release-staging",
        '[ ! -L "$release_stage" ] || {',
        '[ "$(realpath -e -- "$release_stage")" = "$release_stage" ] || {',
        'bash scripts/ci/validate-release-staging.sh "$release_stage"',
        'bash scripts/ci/publish-release.sh "$RELEASE_TAG" "$release_stage"',
    ):
        if token not in publisher_run:
            fail(f"publisher step is missing {token!r}")


def fixture() -> dict:
    return {
        "jobs": {
            "build": {
                "permissions": {"contents": "read"},
                "steps": [
                    {
                        "name": "Upload release assets",
                        "if": RELEASE_GUARD,
                        "run": (
                            "release_stage=out/ci-release/release-staging\n"
                            'release_dir="$release_stage/assets"\n'
                            'notes="$release_dir/BUILD-PARAMETERS.md"\n'
                            "stage_release_file() {\n"
                            '  [ ! -L "$source" ] || { exit 1; }\n'
                            "}\n"
                            'bash scripts/ci/validate-release-staging.sh "$release_stage"\n'
                            'bash scripts/ci/write-release-manifest.sh "$release_stage"\n'
                            'bash scripts/ci/validate-release-staging.sh "$release_stage"'
                        ),
                    },
                    {
                        "name": "Upload staged release payload",
                        "if": RELEASE_GUARD,
                        "uses": UPLOAD,
                        "with": {
                            "name": ARTIFACT_NAME,
                            "path": "out/ci-release/release-staging",
                            "if-no-files-found": "error",
                        },
                    },
                ],
            },
            "publish": {
                "if": RELEASE_GUARD,
                "needs": "build",
                "permissions": {"contents": "write"},
                "steps": [
                    {
                        "name": "Checkout exact release source",
                        "uses": CHECKOUT,
                        "with": {
                            "ref": EXACT_SHA,
                            "persist-credentials": False,
                        },
                    },
                    {
                        "name": "Download staged release payload",
                        "uses": DOWNLOAD,
                        "with": {"name": ARTIFACT_NAME, "path": "release-staging"},
                    },
                    {
                        "name": "Create verified prerelease draft",
                        "env": {
                            "GH_TOKEN": GITHUB_TOKEN,
                            "RELEASE_TAG": "$" + "{{ inputs.release_tag }}",
                            "PRERELEASE": "$"
                            + "{{ inputs.prerelease && '1' || '0' }}",
                        },
                        "run": (
                            '[ "$(git rev-parse HEAD)" = "$GITHUB_SHA" ]\n'
                            "release_stage=$(pwd -P)/release-staging\n"
                            '[ ! -L "$release_stage" ] || { exit 1; }\n'
                            '[ "$(realpath -e -- "$release_stage")" = "$release_stage" ] || { exit 1; }\n'
                            'bash scripts/ci/validate-release-staging.sh "$release_stage"\n'
                            'bash scripts/ci/publish-release.sh "$RELEASE_TAG" '
                            '"$release_stage"'
                        ),
                    },
                ],
            },
        }
    }


def self_test() -> None:
    valid = fixture()
    validate(valid)

    token_in_build = copy.deepcopy(valid)
    token_in_build["jobs"]["build"]["steps"][0]["env"] = {
        "GH_TOKEN": GITHUB_TOKEN
    }
    try:
        validate(token_in_build)
    except SystemExit:
        pass
    else:
        fail("self-test accepted GH_TOKEN in the build job")

    token_at_publish_job = copy.deepcopy(valid)
    token_at_publish_job["jobs"]["publish"]["env"] = {
        "GH_TOKEN": GITHUB_TOKEN
    }
    try:
        validate(token_at_publish_job)
    except SystemExit:
        pass
    else:
        fail("self-test accepted GH_TOKEN at publish job scope")

    mutable_checkout = copy.deepcopy(valid)
    mutable_checkout["jobs"]["publish"]["steps"][0]["with"]["ref"] = "main"
    try:
        validate(mutable_checkout)
    except SystemExit:
        pass
    else:
        fail("self-test accepted a non-exact publish checkout")

    wrong_artifact = copy.deepcopy(valid)
    wrong_artifact["jobs"]["publish"]["steps"][1]["with"]["name"] = "unrelated"
    try:
        validate(wrong_artifact)
    except SystemExit:
        pass
    else:
        fail("self-test accepted an unrelated publication artifact")

    privileged_publish = copy.deepcopy(valid)
    privileged_publish["jobs"]["publish"]["steps"][2]["run"] += "\nsudo true"
    try:
        validate(privileged_publish)
    except SystemExit:
        pass
    else:
        fail("self-test accepted privileged publication")

    print("release job isolation self-test: PASS")


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) != 2:
        fail("usage: test-release-job-isolation.py WORKFLOW|--self-test")
    path = pathlib.Path(sys.argv[1])
    try:
        data = yaml.load(path.read_text(encoding="utf-8"), Loader=WorkflowLoader)
    except yaml.YAMLError as exc:
        fail(f"{path}: invalid YAML: {exc}")
    validate(mapping(data, str(path)))
    print("RELEASE_JOB_ISOLATION=PASS")


if __name__ == "__main__":
    main()
