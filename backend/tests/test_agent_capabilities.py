from app.services.agent_capabilities import (
    apply_capabilities_to_identity_profile,
    filter_secret_keys_for_capabilities,
    resolve_agent_capabilities,
)


def test_resolve_agent_capabilities_normalizes_lists_and_secret_keys() -> None:
    capabilities = resolve_agent_capabilities(
        {
            "capabilities": {
                "policy_name": "worker-min",
                "secret_keys": [" github_token ", "SLACK_TOKEN", "github_token"],
                "required_secret_keys": "github_token, jira_token",
                "skills": "repo-audit\ntriage",
                "file_access": ["/workspace/a", " /workspace/b "],
                "notes": "Least access",
            }
        }
    )

    assert capabilities == {
        "policy_name": "worker-min",
        "secret_keys": ["GITHUB_TOKEN", "SLACK_TOKEN"],
        "required_secret_keys": ["GITHUB_TOKEN", "JIRA_TOKEN"],
        "skills": ["repo-audit", "triage"],
        "file_access": ["/workspace/a", "/workspace/b"],
        "notes": "Least access",
    }


def test_apply_capabilities_to_identity_profile_removes_empty_policy() -> None:
    identity = apply_capabilities_to_identity_profile(
        {"role": "Worker", "capabilities": {"policy_name": "old"}},
        {"policy_name": "", "secret_keys": [], "skills": [], "file_access": []},
    )

    assert identity == {"role": "Worker"}


def test_filter_secret_keys_for_capabilities_limits_returned_secrets() -> None:
    filtered = filter_secret_keys_for_capabilities(
        [
            {"key": "GITHUB_TOKEN", "description": "GitHub"},
            {"key": "SLACK_TOKEN", "description": "Slack"},
        ],
        {"secret_keys": ["SLACK_TOKEN"]},
    )

    assert filtered == [{"key": "SLACK_TOKEN", "description": "Slack"}]
