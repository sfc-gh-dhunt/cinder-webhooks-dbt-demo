"""Render the YAML-bodied agent models with a stub Jinja environment and assert
the keys that matter survive.

This exists because the failure mode is silent: a trimming Jinja comment inside a
whitespace-sensitive YAML body can delete a key without producing invalid YAML, so
`dbt parse` passes, `CREATE AGENT` succeeds, and the agent quietly has no semantic
view attached. Checking the rendered structure is the only way to see it.
"""

import sys
import jinja2
import yaml

CASES = {
    "models/agents/agent_cinder_moderation.sql": [
        ("models",),
        ("instructions", "response"),
        ("instructions", "sample_questions"),
        ("tools",),
        ("tool_resources", "cinder_moderation", "semantic_view"),
        # A Cortex Analyst tool without an execution environment is accepted by
        # CREATE AGENT and works interactively, because the session supplies a
        # warehouse. It fails only when something invokes the agent with no session
        # of its own — an evaluation — with 399504 reported as an ingestion error.
        ("tool_resources", "cinder_moderation", "execution_environment", "warehouse"),
    ],
    "models/agents/eval_cinder_moderation.sql": [
        ("evaluation", "agent_params", "agent_name"),
        ("evaluation", "agent_params", "agent_type"),
        ("evaluation", "source_metadata", "dataset_name"),
        ("metrics",),
    ],
}


def render(path):
    src = open(path).read()
    # `do` is an extension in plain Jinja and a builtin under dbt, so it has to be
    # enabled explicitly or `{% do ref(...) %}` raises "unknown tag".
    env = jinja2.Environment(
        undefined=jinja2.ChainableUndefined,
        extensions=["jinja2.ext.do"],
    )
    tmpl = env.from_string(src)
    return tmpl.render(
        config=lambda **kw: "",
        ref=lambda name: f"CINDER_ANALYTICS.SEMANTIC.{name}",
        var=lambda name, default=None: default,
    )


def get(doc, path):
    node = doc
    for key in path:
        if not isinstance(node, dict) or key not in node:
            return None
        node = node[key]
    return node


failures = []
for path, required in CASES.items():
    rendered = render(path)
    try:
        doc = yaml.safe_load(rendered)
    except yaml.YAMLError as exc:
        failures.append(f"{path}: rendered body is not valid YAML: {exc}")
        continue

    if not isinstance(doc, dict):
        failures.append(
            f"{path}: rendered body is not a mapping, got {type(doc).__name__}"
        )
        continue

    for keypath in required:
        value = get(doc, keypath)
        if value is None:
            failures.append(f"{path}: missing key {'.'.join(keypath)} after rendering")

    # sample_questions entries must be objects carrying a `question` key. A list of
    # bare strings is accepted by YAML and rejected by CREATE AGENT with an error
    # that names neither the key nor the reason.
    sq = get(doc, ("instructions", "sample_questions"))
    if sq is not None:
        for i, entry in enumerate(sq):
            if not isinstance(entry, dict) or "question" not in entry:
                failures.append(
                    f"{path}: sample_questions[{i}] must be a mapping with a "
                    f"'question' key, got {entry!r}"
                )

    # The tool_resources key must match a declared tool name, or the semantic view
    # is attached to nothing.
    tools = get(doc, ("tools",)) or []
    tool_names = {
        t.get("tool_spec", {}).get("name") for t in tools if isinstance(t, dict)
    }
    for resource_name in get(doc, ("tool_resources",)) or {}:
        if resource_name not in tool_names:
            failures.append(
                f"{path}: tool_resources has '{resource_name}' but no tool declares "
                f"that name (declared: {sorted(n for n in tool_names if n)})"
            )

if failures:
    print("Agent spec rendering check FAILED:")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)

print("Agent spec rendering check passed:")
for path in CASES:
    print(f"  - {path}")
