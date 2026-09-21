"""RLM training dashboard (spec Section 11) - rlm.mindcontrolfactor.com.

Runs next to the trainer on the same machine and reads what it writes under rl/runs/:
TensorBoard event files (11.2), eval_log.jsonl, ckpt_*.pt.json sidecars (11.4), status.json
heartbeats, replay sidecars (11.7). Controls go through rl/run.sh (tmux) - the dashboard is a
UI over the v1 launcher, not a second trainer.

    bash rl/run.sh up          # TensorBoard + this dashboard in tmux
    MCF_RLM_PASSWORD=... streamlit run rl/dashboard.py --server.port 8501
"""
from __future__ import annotations

import glob
import hmac
import json
import os
import subprocess
import sys
import time

import pandas as pd
import streamlit as st
import yaml
from tensorboard.backend.event_processing.event_accumulator import EventAccumulator

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
RUNS = os.path.join(HERE, "runs")
RUN_SH = os.path.join(HERE, "run.sh")
CONFIGS = sorted(glob.glob(os.path.join(HERE, "config", "*.yaml")))
TTL = 20  # seconds; the trainer logs once per PPO update, which takes longer than this

st.set_page_config(page_title="Isotope RLM", page_icon="🎯", layout="wide")


# --- auth ------------------------------------------------------------------------------------

def gate() -> None:
    pw = os.environ.get("MCF_RLM_PASSWORD", "")
    if not pw:
        st.error("MCF_RLM_PASSWORD is not set — refusing to serve controls without a password.")
        st.stop()
    if st.session_state.get("auth"):
        return
    with st.form("login"):
        typed = st.text_input("Password", type="password")
        if st.form_submit_button("Enter") and hmac.compare_digest(typed, pw):
            st.session_state.auth = True
            st.rerun()
    st.stop()


# --- data ------------------------------------------------------------------------------------

def branches() -> list[str]:
    if not os.path.isdir(RUNS):
        return []
    return sorted(b for b in os.listdir(RUNS) if os.path.isdir(os.path.join(RUNS, b)))


def read_json(path: str, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (OSError, TypeError):
        return False


def status(branch: str) -> dict:
    """state: running | stopped | dead (heartbeat says running but the pid is gone)."""
    st_ = read_json(os.path.join(RUNS, branch, "status.json"), {}) or {}
    if st_.get("state") == "running" and not pid_alive(st_.get("pid")):
        st_["state"] = "dead"
    st_["age_min"] = (time.time() - st_.get("time", 0)) / 60 if st_ else None
    return st_


@st.cache_data(ttl=TTL, show_spinner=False)
def scalars(branch: str, _stamp: float) -> dict[str, pd.DataFrame]:
    """Every TensorBoard scalar tag of a branch as step/value frames. _stamp busts the cache."""
    tb = os.path.join(RUNS, branch, "tb")
    if not os.path.isdir(tb):
        return {}
    acc = EventAccumulator(tb, size_guidance={"scalars": 0})
    acc.Reload()
    out = {}
    for tag in acc.Tags().get("scalars", []):
        ev = acc.Scalars(tag)
        out[tag] = pd.DataFrame({"step": [e.step for e in ev], tag: [e.value for e in ev]})
    return out


def tb_stamp(branch: str) -> float:
    files = glob.glob(os.path.join(RUNS, branch, "tb", "events.*"))
    return max((os.path.getmtime(f) for f in files), default=0.0)


def evals(branch: str) -> pd.DataFrame:
    path = os.path.join(RUNS, branch, "eval_log.jsonl")
    rows = []
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
    return pd.DataFrame(rows)


def ckpt_meta(path: str) -> dict | None:
    """Sidecar first; a checkpoint written before sidecars existed is read with torch once."""
    meta = read_json(path + ".json")
    if meta is None:
        try:
            import torch
            ck = torch.load(path, map_location="cpu", weights_only=False)
            meta = {k: v for k, v in ck.items() if k not in ("model", "opt", "rng")}
            with open(path + ".json", "w") as f:
                json.dump(meta, f)
        except Exception:
            return None
    return meta


@st.cache_data(ttl=TTL, show_spinner=False)
def checkpoints(_stamp: str) -> pd.DataFrame:
    """The spreadsheet (11.4): one row per checkpoint across every branch, with the latest
    evaluation at or before that step. _stamp is the sorted list of files, to bust the cache."""
    rows = []
    for b in branches():
        ev = evals(b)
        for path in sorted(glob.glob(os.path.join(RUNS, b, "ckpt_*.pt"))):
            m = ckpt_meta(path)
            if not m:
                continue
            cfg = m.get("cfg", {})
            parent = m.get("parent")
            row = dict(branch=b, step=int(m.get("global_step", 0)), update=m.get("update"),
                       matches=m.get("matches_done"), phase=cfg.get("phase"),
                       stage=cfg.get("stage"), opponent=cfg.get("opponent"),
                       maps=len(cfg.get("maps", [])), n_envs=cfg.get("n_envs"),
                       parent=(os.path.relpath(parent, RUNS) if parent else ""),
                       saved=pd.to_datetime(m.get("saved_at", 0), unit="s"),
                       file=os.path.relpath(path, RUNS))
            if not ev.empty and "step" in ev:
                prior = ev[ev["step"] <= row["step"]]
                if not prior.empty:
                    e = prior.iloc[-1]
                    row.update(eval_step=int(e["step"]),
                               win_normal=e.get("winrate_normal"), win_hard=e.get("winrate_hard"),
                               draw_hard=e.get("drawrate_hard"), rounds_hard=e.get("rounds_hard"),
                               value_diff_hard=e.get("value_diff_hard"))
            rows.append(row)
    cols = ["branch", "step", "update", "matches", "phase", "stage", "opponent", "maps", "n_envs",
            "eval_step", "win_normal", "win_hard", "draw_hard", "rounds_hard", "value_diff_hard",
            "parent", "saved", "file"]
    df = pd.DataFrame(rows)
    return df.reindex(columns=cols) if not df.empty else pd.DataFrame(columns=cols)


def ckpt_stamp() -> str:
    return json.dumps(sorted(glob.glob(os.path.join(RUNS, "*", "ckpt_*.pt.json"))))


@st.cache_data(ttl=TTL, show_spinner=False)
def replays(_stamp: str) -> pd.DataFrame:
    """Gallery rows (11.7) from sidecars; replays without one fall back to the file name.
    Outstanding tags: first win vs each opponent per branch, and decisive wins (top quartile
    of end value-diff among that branch's recorded wins)."""
    rows = []
    for path in glob.glob(os.path.join(RUNS, "*", "replays", "*", "*.mcfr")):
        m = read_json(path + ".json") or {}
        name = os.path.basename(path)[:-5].split("_")   # vs_<opp>_<k>_<result>
        rows.append(dict(
            branch=m.get("branch") or path.split(os.sep)[-4],
            step=int(m.get("step", path.split(os.sep)[-2].split("_")[-1] or 0)),
            opponent=m.get("opponent") or (name[1] if len(name) > 1 else "?"),
            result=m.get("result") or (name[-1] if name else "?"),
            value_diff=m.get("value_diff"), rounds=m.get("rounds"),
            map=os.path.basename(str(m.get("map", ""))).replace(".json", ""),
            date=pd.to_datetime(m.get("time") or os.path.getmtime(path), unit="s"),
            source="training", file=path))
    df = pd.DataFrame(rows)
    if df.empty:
        return df
    df = df.sort_values(["branch", "step", "opponent"]).reset_index(drop=True)
    tags = [[] for _ in range(len(df))]
    wins = df[df["result"] == "win"]
    for _, g in wins.groupby(["branch", "opponent"]):
        tags[g.index[0]].append("first win vs " + g["opponent"].iloc[0])
    for _, g in wins.groupby("branch"):
        vd = g["value_diff"].dropna()
        if len(vd) >= 4:
            q = vd.quantile(0.75)
            for i in vd[vd >= q].index:
                tags[i].append("decisive")
    df["outstanding"] = [", ".join(t) for t in tags]
    return df


def replay_stamp() -> str:
    return json.dumps(sorted(glob.glob(os.path.join(RUNS, "*", "replays", "*", "*.mcfr"))))


def branch_cfg(branch: str) -> dict:
    try:
        with open(os.path.join(RUNS, branch, "config.yaml")) as f:
            return yaml.safe_load(f) or {}
    except OSError:
        return {}


def godot_bin() -> str:
    return os.environ.get("GODOT", "godot")


# --- actions (all through rl/run.sh) --------------------------------------------------------

def run_sh(*args: str) -> str:
    r = subprocess.run(["bash", RUN_SH, *args], capture_output=True, text=True, cwd=PROJECT)
    out = (r.stdout + r.stderr).strip()
    (st.success if r.returncode == 0 else st.error)(f"`run.sh {' '.join(args)}`\n\n{out or 'ok'}")
    st.cache_data.clear()
    return out


def write_next_config(branch: str, text: str) -> str | None:
    try:
        cfg = yaml.safe_load(text) or {}
        assert isinstance(cfg, dict)
    except Exception as e:
        st.error(f"not valid YAML: {e}")
        return None
    path = os.path.join(RUNS, branch, "config.next.yaml")
    with open(path, "w") as f:
        yaml.safe_dump(cfg, f)
    return path


def launch_game(*user_args: str) -> None:
    """The real game as a local process (11.6 / 11.7) - the dashboard runs on the laptop."""
    cmd = [godot_bin(), "--path", PROJECT, "--", *user_args]
    try:
        subprocess.Popen(cmd, cwd=PROJECT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        st.success("launched: `" + " ".join(cmd) + "`")
    except OSError as e:
        st.error(f"could not start Godot (`GODOT={godot_bin()}`): {e}")


def play_vs(ckpt_rel: str) -> None:
    py = os.environ.get("MCF_RL_PYTHON") or sys.executable
    cmd = [py, os.path.join(HERE, "train.py"), "play", os.path.join(RUNS, ckpt_rel),
           "--godot", godot_bin()]
    subprocess.Popen(cmd, cwd=PROJECT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    st.success("launched the game with this checkpoint in the AI slot (policy server on :7791)")


# --- pages -----------------------------------------------------------------------------------

def chart(sc: dict, tags: list[str], title: str) -> None:
    frames = [sc[t].set_index("step") for t in tags if t in sc]
    if not frames:
        return
    st.caption(title)
    st.line_chart(pd.concat(frames, axis=1).sort_index(), height=220)


def page_overview() -> None:
    st.header("Runs")
    rows = []
    for b in branches():
        s = status(b)
        ev = evals(b)
        last = ev.iloc[-1] if not ev.empty else {}
        rows.append(dict(branch=b, state=s.get("state", "—"), step=s.get("step"),
                         update=s.get("update"), matches=s.get("matches"), phase=s.get("phase"),
                         stage=s.get("stage"),
                         win_normal=last.get("winrate_normal"), win_hard=last.get("winrate_hard"),
                         heartbeat_min=round(s["age_min"], 1) if s.get("age_min") is not None else None))
    if rows:
        st.dataframe(pd.DataFrame(rows), width="stretch", hide_index=True)
    else:
        st.info("No runs yet — start one below.")

    st.subheader("Start a new run")
    with st.form("start"):
        name = st.text_input("Branch name", placeholder="phaseA-1")
        base = st.selectbox("Config", CONFIGS, format_func=os.path.basename)
        text = st.text_area("YAML (edit before starting)", open(base).read() if base else "",
                            height=260)
        if st.form_submit_button("Start training") and name:
            if name in branches():
                st.error("branch exists — resume it from its page, or pick another name")
            else:
                os.makedirs(os.path.join(RUNS, name), exist_ok=True)
                path = write_next_config(name, text)
                if path:
                    run_sh("start", path, name)


def page_branch(b: str) -> None:
    s = status(b)
    cfg = branch_cfg(b)
    st.header(b)
    c1, c2, c3, c4, c5 = st.columns(5)
    c1.metric("state", s.get("state", "—"))
    c2.metric("step", s.get("step", "—"))
    c3.metric("phase / stage", f"{cfg.get('phase', '?')} / {cfg.get('stage', '?')}")
    c4.metric("matches", s.get("matches", "—"))
    c5.metric("heartbeat", f"{s['age_min']:.0f} min ago" if s.get("age_min") is not None else "—")

    @st.fragment(run_every=30)
    def live() -> None:
        sc = scalars(b, tb_stamp(b))
        if not sc:
            st.info("no TensorBoard data yet")
            return
        a, bcol = st.columns(2)
        with a:
            chart(sc, ["train/winrate_vs_ai", "train/winrate_vs_pool", "train/drawrate"], "win / draw rate (training)")
            chart(sc, ["eval/winrate_normal", "eval/winrate_hard"], "greedy eval win rate (§8.2 reference: 0.55 vs NORMAL to graduate)")
            chart(sc, ["train/value_diff_end", "eval/value_diff_hard"], "army-value differential at match end")
            chart(sc, ["train/match_rounds", "eval/rounds_hard"], "match length (rounds)")
        with bcol:
            chart(sc, ["ppo/policy_loss", "ppo/value_loss"], "PPO losses")
            chart(sc, ["ppo/entropy", "ppo/approx_kl"], "entropy / KL")
            chart(sc, ["speed/env_steps_per_sec", "speed/update_secs"], "speed")
            chart(sc, ["train/illegal_per_match"], "illegal intents per match (should stay 0)")
        usage = {t.split("_", 1)[1]: df.iloc[-1, 1] for t, df in sc.items() if t.startswith("usage/unit_")}
        kinds = {t.split("_", 1)[1]: df.iloc[-1, 1] for t, df in sc.items() if t.startswith("usage/kind_")}
        a, bcol = st.columns(2)
        if usage:
            a.caption("unit usage, latest update")
            a.bar_chart(pd.Series(usage).sort_values(ascending=False), height=220)
        if kinds:
            bcol.caption("intent-kind usage, latest update")
            bcol.bar_chart(pd.Series(kinds).sort_values(ascending=False), height=220)
    live()

    st.subheader("Controls")
    running = s.get("state") == "running"
    c1, c2, c3 = st.columns(3)
    if c1.button("Stop (checkpoint after this update)", disabled=not running, key="stop"):
        run_sh("stop", b)
    if c2.button("Resume from latest", disabled=running, key="resume"):
        run_sh("resume", b)
    if c3.button("Play vs latest checkpoint (opens the game)", key="play"):
        play_vs(os.path.join(b, "latest.pt"))

    st.markdown("**Config** — edits apply by stop → resume under the new config (§11.3)")
    text = st.text_area("config.yaml", yaml.safe_dump(cfg, sort_keys=False), height=300, key=f"cfg-{b}")
    c1, c2 = st.columns(2)
    if c1.button("Apply config (restart)", key="apply"):
        path = write_next_config(b, text)
        if path:
            run_sh("restart", b, path)
    grad = dict(cfg, phase="B", opponent="hard")
    if c2.button("Graduate → Phase B, HARD teacher (§8.2)", disabled=cfg.get("phase") == "B", key="grad"):
        path = write_next_config(b, yaml.safe_dump(grad))
        if path:
            run_sh("restart", b, path)

    st.subheader("Fork")
    cks = checkpoints(ckpt_stamp())
    mine = cks[cks["branch"] == b]
    with st.form("fork"):
        src = st.selectbox("From checkpoint", list(mine["file"]) if not mine.empty else [])
        name = st.text_input("New branch name")
        if st.form_submit_button("Fork and train") and src and name:
            if name in branches():
                st.error("branch exists")
            else:
                run_sh("fork", src, name)

    st.subheader("Evaluations")
    ev = evals(b)
    if not ev.empty:
        ev = ev.copy()
        ev["time"] = pd.to_datetime(ev["time"], unit="s")
        st.dataframe(ev, width="stretch", hide_index=True)
    with st.expander("log tail"):
        log = os.path.join(RUNS, f"{b}.log")
        if os.path.exists(log):
            with open(log, "rb") as f:
                f.seek(max(0, os.path.getsize(log) - 8000))
                st.code(f.read().decode("utf-8", "replace"))


def page_checkpoints() -> None:
    st.header("Checkpoints — every branch")
    df = checkpoints(ckpt_stamp())
    if df.empty:
        st.info("no checkpoints yet")
        return
    st.caption("Sort by clicking a header. `parent` shows fork lineage (§11.4).")
    sel = st.dataframe(df, width="stretch", hide_index=True, on_select="rerun",
                       selection_mode="single-row")
    st.download_button("Download CSV", df.to_csv(index=False).encode(), "isotope_rlm_checkpoints.csv",
                       "text/csv")
    rows = sel.get("selection", {}).get("rows", []) if isinstance(sel, dict) else sel.selection.rows
    if rows:
        row = df.iloc[rows[0]]
        st.markdown(f"Selected **{row['file']}**")
        c1, c2 = st.columns(2)
        with c1.form("fork-ck"):
            name = st.text_input("Fork into new branch")
            if st.form_submit_button("Fork") and name:
                if name in branches():
                    st.error("branch exists")
                else:
                    run_sh("fork", row["file"], name)
        if c2.button("Play against this checkpoint"):
            play_vs(row["file"])
    st.subheader("Lineage")
    for _, r in df.drop_duplicates("branch").iterrows():
        st.text(f"{r['branch']}  ←  {r['parent'] or 'root'}")


def page_replays() -> None:
    st.header("Replays")
    df = replays(replay_stamp())
    if df.empty:
        st.info("no replays yet — the trainer records a few per evaluation")
        return
    c1, c2, c3, c4 = st.columns(4)
    fb = c1.multiselect("branch", sorted(df["branch"].unique()))
    fo = c2.multiselect("opponent", sorted(df["opponent"].unique()))
    fr = c3.multiselect("result", sorted(df["result"].unique()))
    only = c4.checkbox("outstanding only")
    v = df
    if fb: v = v[v["branch"].isin(fb)]
    if fo: v = v[v["opponent"].isin(fo)]
    if fr: v = v[v["result"].isin(fr)]
    if only: v = v[v["outstanding"] != ""]
    v = v.sort_values("date", ascending=False).reset_index(drop=True)
    show = v.drop(columns=["file"])
    sel = st.dataframe(show, width="stretch", hide_index=True, on_select="rerun",
                       selection_mode="single-row")
    rows = sel.get("selection", {}).get("rows", []) if isinstance(sel, dict) else sel.selection.rows
    if rows:
        path = v.iloc[rows[0]]["file"]
        c1, c2 = st.columns(2)
        if c1.button("Open in the game's replay viewer"):
            launch_game(f"--replay={path}")
        with open(path, "rb") as f:
            c2.download_button("Download .mcfr", f.read(), os.path.basename(path))


def page_maps() -> None:
    st.header("Per-map stats (§11.8)")
    rows, series = [], {}
    for b in branches():
        sc = scalars(b, tb_stamp(b))
        for tag, df in sc.items():
            if not tag.startswith("map/") or not tag.endswith("_winrate"):
                continue
            mp = tag[len("map/"):-len("_winrate")]
            tail = df.tail(10)
            slope = 0.0
            if len(tail) > 1:
                x = tail["step"].astype(float)
                y = tail[tag].astype(float)
                slope = float(((x - x.mean()) * (y - y.mean())).sum() / max(1e-9, ((x - x.mean()) ** 2).sum()))
            rows.append(dict(map=mp, branch=b, points=len(df), latest=round(float(df.iloc[-1, 1]), 3),
                             mean=round(float(df[tag].mean()), 3),
                             trend="↑ improving" if slope > 0 else "↓ regressing" if slope < 0 else "flat"))
            series[f"{b} · {mp}"] = df.set_index("step")[tag]   # no ":" — Altair reads it as a type hint
    if not rows:
        st.info("no per-map data yet")
        return
    st.dataframe(pd.DataFrame(rows).sort_values(["map", "branch"]), width="stretch", hide_index=True)
    st.caption("training win rate per map, per branch")
    st.line_chart(pd.concat(series, axis=1).sort_index(), height=300)


def main() -> None:
    gate()
    st.sidebar.title("Isotope RLM")
    bs = branches()
    page = st.sidebar.radio("Page", ["Overview", "Branch", "Checkpoints", "Replays", "Maps"])
    if st.sidebar.button("Refresh data"):
        st.cache_data.clear()
        st.rerun()
    st.sidebar.caption(f"runs: `{RUNS}`\n\nGodot: `{godot_bin()}`")
    if page == "Overview":
        page_overview()
    elif page == "Branch":
        if not bs:
            st.info("no runs yet")
        else:
            page_branch(st.sidebar.selectbox("Branch", bs))
    elif page == "Checkpoints":
        page_checkpoints()
    elif page == "Replays":
        page_replays()
    else:
        page_maps()


main()
