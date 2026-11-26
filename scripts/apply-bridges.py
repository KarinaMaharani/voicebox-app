"""Re-apply graphify-out/bridges.json to graphify-out/graph.json.

The AST pass and the semantic pass never meet: AST emits symbol nodes from source
files, semantic extraction emits concept nodes from READMEs, and nothing links a
documented capability to the symbol that implements it. bridges.json holds those
links by hand; this script merges them into the graph, re-clusters, carries the
curated community labels over, and regenerates the report.

Run it after any `graphify --update`, which re-extracts the doc files and drops
their edges:

    python scripts/apply-bridges.py

Endpoints are validated against the live graph. A bridge naming a node that no
longer exists is reported and skipped, never silently dropped.
"""

import json
import sys
from collections import Counter
from pathlib import Path

from graphify.analyze import god_nodes, suggest_questions, surprising_connections
from graphify.build import build_from_json
from graphify.cluster import cluster, score_all
from graphify.detect import detect
from graphify.export import to_json
from graphify.paths import out_path
from graphify.report import generate
from graphify.watch import _read_build_excludes, _read_build_gitignore

OUT = Path("graphify-out")
GRAPH = OUT / "graph.json"
BRIDGES = OUT / "bridges.json"


def main() -> int:
    if not GRAPH.is_file():
        print(f"ERROR: {GRAPH} not found - build the graph first.", file=sys.stderr)
        return 1
    if not BRIDGES.is_file():
        print(f"ERROR: {BRIDGES} not found - nothing to apply.", file=sys.stderr)
        return 1

    root = (OUT / ".graphify_root").read_text(encoding="utf-8-sig").strip()
    g = json.loads(GRAPH.read_text(encoding="utf-8"))
    bridges = json.loads(BRIDGES.read_text(encoding="utf-8"))

    node_ids = {n["id"] for n in g["nodes"]}

    # Carry the curated community names forward before re-clustering discards them.
    prior_label = {n["id"]: n.get("community_name") for n in g["nodes"]}

    existing = {
        (e["source"], e["target"], e.get("relation"))
        for e in g["links"]
    }

    applied, skipped, duplicate = [], [], 0
    for e in bridges.get("edges", []):
        missing = [x for x in (e["source"], e["target"]) if x not in node_ids]
        if missing:
            skipped.append((e["source"], e["target"], missing))
            continue
        if (e["source"], e["target"], e.get("relation")) in existing:
            duplicate += 1
            continue
        applied.append(e)

    for src, tgt, missing in skipped:
        print(f"  SKIP {src} -> {tgt}: endpoint not in graph: {', '.join(missing)}")
    if duplicate:
        print(f"  {duplicate} bridge(s) already present - not re-added")

    extraction = {
        "nodes": g["nodes"],
        "edges": g["links"] + applied,
        "hyperedges": g.get("hyperedges", []),
    }

    G = build_from_json(extraction, root=root, directed=False)
    if G.number_of_nodes() == 0:
        print("ERROR: graph is empty after merge - refusing to write.", file=sys.stderr)
        return 1

    communities = cluster(G)
    cohesion = score_all(G, communities)
    gods = god_nodes(G)
    surprises = surprising_connections(G, communities)

    # Name each new community after the most common prior label among its members,
    # so hand-curated names survive re-clustering instead of reverting to "Community N".
    labels = {}
    used = Counter()
    for cid, members in communities.items():
        votes = Counter(
            prior_label[m] for m in members if prior_label.get(m)
        )
        if votes:
            name = votes.most_common(1)[0][0]
            used[name] += 1
            if used[name] > 1:
                name = f"{name} ({used[name]})"
            labels[cid] = name
        else:
            labels[cid] = f"Community {cid}"

    detection = detect(
        Path(root),
        extra_excludes=_read_build_excludes(out_path()),
        gitignore=_read_build_gitignore(out_path()),
    )

    cost = json.loads((OUT / "cost.json").read_text(encoding="utf-8"))
    tokens = {
        "input": cost.get("total_input_tokens", 0),
        "output": cost.get("total_output_tokens", 0),
    }

    questions = suggest_questions(G, communities, labels)

    # force=True: the bridges add edges, not nodes, so the node count is unchanged
    # and the #479 shrink-guard has nothing to compare; force keeps an equal-size
    # rewrite from being refused.
    wrote = to_json(G, communities, str(GRAPH), community_labels=labels, force=True)
    if not wrote:
        print(f"ERROR: refused to write {GRAPH}.", file=sys.stderr)
        return 1

    report = generate(
        G, communities, cohesion, labels, gods, surprises,
        detection, tokens, root, suggested_questions=questions,
    )
    (OUT / "GRAPH_REPORT.md").write_text(report, encoding="utf-8")
    (OUT / ".graphify_labels.json").write_text(
        json.dumps({str(k): v for k, v in labels.items()}, ensure_ascii=False),
        encoding="utf-8",
    )

    print(
        f"Applied {len(applied)} bridge edge(s); "
        f"{len(skipped)} skipped. "
        f"Graph: {G.number_of_nodes()} nodes, {G.number_of_edges()} edges, "
        f"{len(communities)} communities."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
