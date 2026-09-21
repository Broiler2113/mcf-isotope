"""Rebuild the MCF knowledge graph. graphify has no GDScript support, so code nodes come
from .gd_extract.py; docs come from graphify's semantic cache (refresh with /graphify --update).
Run from the repo root: python graphify-out/rebuild.py"""
import json, os, re, subprocess, sys, collections
from pathlib import Path
os.environ.setdefault('PYTHONHASHSEED', '0')
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'graphify-out'
os.chdir(ROOT)
from graphify.build import build_from_json
from graphify.cluster import cluster, score_all
from graphify.analyze import god_nodes, surprising_connections, suggest_questions
from graphify.report import generate
from graphify.export import to_json
from graphify.cache import check_semantic_cache

# 1. code (custom extractor appends into .graphify_ast.json)
ast_path = OUT / '.graphify_ast.json'
ast_path.write_text(json.dumps({'nodes': [], 'edges': [], 'input_tokens': 0, 'output_tokens': 0}))
subprocess.run([sys.executable, str(OUT / '.gd_extract.py')], check=True)
ast = json.loads(ast_path.read_text(encoding='utf-8'))

# 2. docs from semantic cache (never re-extracted here; that needs an LLM)
docs = [str(p) for pat in ('*.md', '*.txt') for p in ROOT.rglob(pat) if 'graphify-out' not in p.parts and '.godot' not in p.parts]
sn, se, sh, _ = check_semantic_cache(docs, root=str(ROOT), prompt_file=str(Path.home() / '.claude/skills/graphify/references/extraction-spec.md'))
ids = {n['id'] for n in ast['nodes']}
lower = {i.lower(): i for i in ids}
fix = lambda i: lower.get(i.lower(), i)  # docs cite ids in lowercase
for e in se: e['source'], e['target'] = fix(e['source']), fix(e['target'])
for h in sh: h['nodes'] = [fix(i) for i in h['nodes']]
ext = {'nodes': ast['nodes'] + [n for n in sn if n['id'] not in ids], 'edges': ast['edges'] + se, 'hyperedges': sh, 'input_tokens': 0, 'output_tokens': 0}

# 3. build + cluster
G = build_from_json(ext, root=str(ROOT), directed=False)
assert G.number_of_nodes() > 0, 'empty graph'
comms = cluster(G); coh = score_all(G, comms)
# ponytail: label = dominant class/file of the community; hand-curated labels in .graphify_labels.json
# don't survive re-clustering because community ids are not stable.
def label(members):
    c = collections.Counter(G.nodes[m].get('label', m).split('.')[0] for m in members)
    top = [k for k, _ in c.most_common(2)]
    return ' / '.join(top)
labels = {cid: label(m) for cid, m in comms.items()}
gods = god_nodes(G); sur = surprising_connections(G, comms); qs = suggest_questions(G, comms, labels)
detection = {'total_files': len(docs) + len({n['source_file'] for n in ast['nodes']}), 'total_words': 0, 'files': {'code': [], 'document': docs}}
to_json(G, comms, str(OUT / 'graph.json'), community_labels=labels, force=True)  # full rebuild: deletions are legitimate
(OUT / 'GRAPH_REPORT.md').write_text(generate(G, comms, coh, labels, gods, sur, detection, {'input': 0, 'output': 0}, str(ROOT), suggested_questions=qs), encoding='utf-8')
ast_path.unlink()

# 4. html, self-contained (CDN script blocked in previews)
subprocess.run(['graphify', 'export', 'html'], check=True, capture_output=True)
h = (OUT / 'graph.html').read_text(encoding='utf-8')
h, n = re.subn(r'<script src="https://unpkg\.com/vis-network[^"]*"[^>]*></script>', lambda m: '<script>' + (OUT / 'vis-network.min.js').read_text(encoding='utf-8') + '</script>', h, count=1)
assert n == 1
(OUT / 'graph.html').write_text(h, encoding='utf-8')
print(f'graph: {G.number_of_nodes()} nodes, {G.number_of_edges()} edges, {len(comms)} communities')
