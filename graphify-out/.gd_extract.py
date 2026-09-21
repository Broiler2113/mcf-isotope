"""Deterministic GDScript extractor in graphify's AST JSON shape (no LLM).
Nodes: file, class (class_name), func. Edges: contains, extends, calls (Class.func / bare func
resolved against known names), references (ClassName mentioned in body)."""
import json, re, sys
from pathlib import Path

root = Path('.').resolve()
files = sorted(p for p in root.rglob('*.gd') if '.godot' not in p.parts and 'graphify-out' not in p.parts)
nodes, edges = [], []
def nid(s): return re.sub(r'[^A-Za-z0-9_]', '_', s)

class_of_file, funcs_of_class, file_meta = {}, {}, {}
for p in files:
    rel = p.relative_to(root).as_posix()
    src = p.read_text(encoding='utf-8', errors='replace')
    m = re.search(r'^class_name\s+(\w+)', src, re.M)
    cls = m.group(1) if m else p.stem
    class_of_file[rel] = cls
    ext = re.search(r'^extends\s+"?([\w./:]+)"?', src, re.M)
    funcs = [(fm.group(1), src[:fm.start()].count('\n') + 1, fm.end()) for fm in re.finditer(r'^(?:static\s+)?func\s+(\w+)\s*\(', src, re.M)]
    funcs_of_class[cls] = {f[0] for f in funcs}
    file_meta[rel] = (cls, ext.group(1) if ext else None, funcs, src)

all_classes = set(funcs_of_class)
for rel, (cls, ext, funcs, src) in file_meta.items():
    fid = nid(rel[:-3])
    nodes.append({"id": fid, "label": Path(rel).name, "file_type": "code", "source_file": rel, "source_location": "L1",
                  "metadata": {"language": "gdscript", "kind": "file"}, "_origin": "ast"})
    cid = "gd_" + nid(cls)
    nodes.append({"id": cid, "label": cls, "file_type": "code", "source_file": rel, "source_location": "L1",
                  "metadata": {"language": "gdscript", "kind": "class"}, "_origin": "ast"})
    edges.append({"source": fid, "target": cid, "relation": "contains", "confidence": "EXTRACTED", "source_file": rel, "source_location": "L1", "weight": 1.0, "_origin": "ast"})
    if ext:
        base = Path(ext).stem if '/' in ext else ext
        if base in all_classes:
            edges.append({"source": cid, "target": "gd_" + nid(base), "relation": "extends", "confidence": "EXTRACTED", "source_file": rel, "source_location": "L1", "weight": 1.0, "_origin": "ast"})
    # class references in body (autoload/global class names)
    for other in all_classes:
        if other != cls and re.search(r'\b' + re.escape(other) + r'\b', src):
            edges.append({"source": cid, "target": "gd_" + nid(other), "relation": "references", "confidence": "EXTRACTED", "source_file": rel, "source_location": "L1", "weight": 0.5, "_origin": "ast"})
    # functions and calls
    for i, (fname, line, body_start) in enumerate(funcs):
        body_end = funcs[i + 1][2] if i + 1 < len(funcs) else len(src)
        body = src[body_start:body_end]
        fnid = cid + "__" + nid(fname)
        nodes.append({"id": fnid, "label": f"{cls}.{fname}", "file_type": "code", "source_file": rel, "source_location": f"L{line}",
                      "metadata": {"language": "gdscript", "kind": "function"}, "_origin": "ast"})
        edges.append({"source": cid, "target": fnid, "relation": "contains", "confidence": "EXTRACTED", "source_file": rel, "source_location": f"L{line}", "weight": 1.0, "_origin": "ast"})
        seen = set()
        for cm in re.finditer(r'(?:(\w+)\.)?(\w+)\s*\(', body):
            q, callee = cm.group(1), cm.group(2)
            if callee == fname and not q: continue
            target = None
            if q in all_classes and callee in funcs_of_class[q]:
                target = "gd_" + nid(q) + "__" + nid(callee)
            elif not q and callee in funcs_of_class[cls]:
                target = cid + "__" + nid(callee)
            elif q in (None, 'self', 'resolver', 'r', 'state', 'st', 'net', 'session') :
                owners = [c for c in all_classes if callee in funcs_of_class[c] and c != cls]
                if len(owners) == 1: target = "gd_" + nid(owners[0]) + "__" + nid(callee)
            if target and target not in seen:
                seen.add(target)
                edges.append({"source": fnid, "target": target, "relation": "calls", "confidence": "EXTRACTED" if (q in all_classes or (not q and callee in funcs_of_class[cls])) else "INFERRED",
                              "source_file": rel, "source_location": f"L{line}", "weight": 1.0, "_origin": "ast"})

ast = json.loads(Path('graphify-out/.graphify_ast.json').read_text(encoding='utf-8'))
ids = {n['id'] for n in ast['nodes']}
ast['nodes'] += [n for n in nodes if n['id'] not in ids]
ast['edges'] += edges
Path('graphify-out/.graphify_ast.json').write_text(json.dumps(ast, indent=2, ensure_ascii=False), encoding='utf-8')
print(f'GDScript: {len(files)} files, {len(nodes)} nodes, {len(edges)} edges -> AST total {len(ast["nodes"])} nodes, {len(ast["edges"])} edges')
