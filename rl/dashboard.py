"""RLM training dashboard (spec Section 11) - rlm.mindcontrolfactor.com.

Runs next to the trainer on the same machine and reads what it writes under rl/runs/:
TensorBoard event files (11.2), eval_log.jsonl, ckpt_*.pt.json sidecars (11.4), status.json
heartbeats, replay sidecars (11.7). Controls go through rl/run.sh (nohup + pid files) - the dashboard is a
UI over the v1 launcher, not a second trainer.

    bash rl/run.sh up          # TensorBoard + this dashboard in the background
    MCF_RLM_PASSWORD=... streamlit run rl/dashboard.py --server.port 8501
"""
from __future__ import annotations

import glob
import hashlib
import hmac
import json
import os
import secrets
import subprocess
import sys
import time
from datetime import datetime, timedelta

import altair as alt
import extra_streamlit_components as stx
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

st.set_page_config(page_title="Isotope RLM", layout="wide")

# --- palette ---------------------------------------------------------------------------------
#
# The dataviz reference palette, dark steps, on its documented dark surface (#1a1a19) —
# taken unchanged rather than invented, because that exact combination is the validated
# one (worst adjacent CVD dE 8.4). Two rules ride on this and are easy to break by
# accident:
#   * Categorical hues are assigned in FIXED slot order and never cycled. An entity keeps
#     its colour when a filter changes the series count.
#   * Only line and stacked forms here, so the *adjacent* pairlist applies and all eight
#     slots are legal. A scatter of >3 series would need a different (smaller) set.
# STATUS is separate and never used for a series: it always ships with a word beside it.
SURFACE = "#1a1a19"
PLANE = "#0d0d0d"
INK = "#ffffff"
INK_DIM = "#c3c2b7"
GRID = "#383835"
SERIES = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"]
STATUS = {"good": "#0ca30c", "warning": "#fab219", "serious": "#ec835a", "critical": "#d03b3b"}

# Outcome -> fixed slot. Win leads; the two draws sit together because they are read
# together ("did it stall or run out of rounds?").
OUTCOME_ORDER = ["win", "loss", "draw_cap", "draw_steps", "draw"]
OUTCOME_COLOR = dict(zip(OUTCOME_ORDER, SERIES))

# Mirrors train.py's DEFAULTS["eval_opponents"], for branches whose config.yaml predates
# the key. Without it an old branch would keep showing its retired NORMAL column.
DEFAULT_EVAL_OPPONENTS = ["hard"]

THEME_CSS = f"""
<style>
  .stApp {{ background: {PLANE}; }}
  section[data-testid="stSidebar"] {{ background: {SURFACE}; border-right: 1px solid {GRID}; }}
  h1, h2, h3 {{ letter-spacing: -0.01em; }}
  h1 {{ font-weight: 700; }}
  /* Metric tiles read as cards so a row of them scans as one instrument panel. */
  div[data-testid="stMetric"] {{
      background: {SURFACE}; border: 1px solid {GRID}; border-radius: 10px;
      padding: 12px 14px 10px 14px;
  }}
  div[data-testid="stMetricLabel"] {{ color: {INK_DIM}; text-transform: uppercase;
      font-size: 0.68rem; letter-spacing: 0.08em; }}
  div[data-testid="stMetricValue"] {{ font-size: 1.6rem; font-weight: 650;
      font-variant-numeric: tabular-nums; }}
  .rlm-card {{ background: {SURFACE}; border: 1px solid {GRID}; border-radius: 12px;
      padding: 14px 16px; margin-bottom: 10px; }}
  .rlm-pill {{ display: inline-block; padding: 2px 10px; border-radius: 999px;
      font-size: 0.72rem; font-weight: 650; letter-spacing: 0.04em;
      text-transform: uppercase; border: 1px solid; }}
  .rlm-sub {{ color: {INK_DIM}; font-size: 0.82rem; font-variant-numeric: tabular-nums; }}
  .rlm-sub b {{ color: {INK}; font-weight: 600; }}
  code, pre, .stCode {{ font-variant-ligatures: none; }}
  .stButton button {{ border-radius: 8px; font-weight: 600; }}
</style>
"""

# state -> status role. The state is always written out in words inside the pill, so the
# colour never carries the meaning on its own.
STATE_STYLE = {
    "running": "good", "paused": "warning", "starting": "warning",
    "stopped": "serious", "dead": "critical", "crashed": "critical",
}


def pill(text: str, role: str) -> str:
    c = STATUS.get(role, INK_DIM)
    return (f'<span class="rlm-pill" style="color:{c};border-color:{c};'
            f'background:{c}1a">{text}</span>')




# --- auth ------------------------------------------------------------------------------------

AUTH_COOKIE = "mcf_rlm_session"
SESSIONS = os.path.join(RUNS, ".sessions.json")
SESSION_DAYS = 14


def cookie_jar():
    """CookieManager, created only when something actually needs to WRITE a cookie.

    Reading goes through st.context.cookies instead (see _cookie_token): the component's
    .get() is asynchronous — on the first run of a fresh page load it returns None, the
    login form renders, st.stop() halts the script, and the cookie round-trip never gets
    to matter. That is why "stay signed in" appeared to do nothing on refresh. The server
    already has the request cookies, so reading needs no component at all."""
    return stx.CookieManager(key="rlm-auth")


def _cookie_token() -> str | None:
    """The session cookie as the browser sent it with THIS request. Deterministic and
    available on the very first script run, unlike the component's async read."""
    try:
        tok = st.context.cookies.get(AUTH_COOKIE)
    except Exception:
        return None
    # A cookie is a string or it is nothing. Anything else (a stub under the test
    # harness, a future API change) must not reach sha256 and blow up the login page.
    return tok if isinstance(tok, str) and tok else None


def _sessions() -> dict:
    return read_json(SESSIONS, {}) or {}


def _issue_token() -> str:
    """A fresh random session token. Only its SHA-256 is stored, so the file on disk
    cannot be replayed as a login; expired entries are pruned on every issue."""
    tok = secrets.token_urlsafe(32)
    live = {k: v for k, v in _sessions().items() if float(v) > time.time()}
    live[hashlib.sha256(tok.encode()).hexdigest()] = time.time() + SESSION_DAYS * 86400
    os.makedirs(RUNS, exist_ok=True)
    tmp = SESSIONS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(live, f)
    os.replace(tmp, SESSIONS)
    os.chmod(SESSIONS, 0o600)
    return tok


def _token_valid(tok: str | None) -> bool:
    if not isinstance(tok, str) or not tok:
        return False
    return float(_sessions().get(hashlib.sha256(tok.encode()).hexdigest(), 0)) > time.time()


def _sign_out(tok: str | None) -> None:
    if tok:
        live = {k: v for k, v in _sessions().items()
                if k != hashlib.sha256(tok.encode()).hexdigest()}
        with open(SESSIONS, "w") as f:
            json.dump(live, f)
    try:
        cookie_jar().delete(AUTH_COOKIE, key="rlm-signout")
    except Exception:
        pass       # the token is already revoked server-side; a stale cookie cannot log in
    st.session_state.pop("auth", None)


def gate() -> None:
    pw = os.environ.get("MCF_RLM_PASSWORD", "")
    if not pw:
        st.error("MCF_RLM_PASSWORD is not set — refusing to serve controls without a password.")
        st.stop()
    if st.session_state.get("auth"):
        return
    tok = _cookie_token()
    if _token_valid(tok):
        st.session_state.auth = True
        st.session_state["auth_token"] = tok
        return
    with st.form("login"):
        typed = st.text_input("Password", type="password")
        keep = st.checkbox(f"Stay signed in on this browser for {SESSION_DAYS} days",
                           value=True)
        submitted = st.form_submit_button("Enter")
    if submitted and hmac.compare_digest(typed, pw):
        st.session_state.auth = True
        if keep:
            fresh = _issue_token()
            st.session_state["auth_token"] = fresh
            # Deliberately NO st.rerun() here: .set() is a component call that has to
            # execute before the cookie exists in the browser, and rerunning immediately
            # threw that away — the login "worked" but nothing was ever written.
            cookie_jar().set(AUTH_COOKIE, fresh, key="rlm-set",
                             expires_at=datetime.now() + timedelta(days=SESSION_DAYS))
        return
    st.stop()


# --- data ------------------------------------------------------------------------------------

def branches() -> list[str]:
    """Real training branches. A leading underscore marks a scratch directory — `_eval`
    from `train.py eval`, a profiling run — and those are not branches anybody wants
    listed or offered controls for."""
    if not os.path.isdir(RUNS):
        return []
    return sorted(b for b in os.listdir(RUNS)
                  if os.path.isdir(os.path.join(RUNS, b)) and not b.startswith("_"))


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
    """state: running | paused | stopped | crashed (the trainer raised and said so) |
    dead (heartbeat said running but the pid is gone — nobody got to write a reason) |
    starting | never started."""
    st_ = read_json(os.path.join(RUNS, branch, "status.json"), {}) or {}
    if st_.get("state") in ("running", "paused") and not pid_alive(st_.get("pid")):
        st_["state"] = "dead"
    if not st_:
        pidfile = os.path.join(RUNS, f"{branch}.pid")
        st_["state"] = "never started" if not os.path.exists(pidfile) else (
            "starting" if pid_alive(read_pid(pidfile)) else "crashed")
    st_["age_s"] = time.time() - st_["time"] if "time" in st_ else None
    st_["age_min"] = st_["age_s"] / 60 if st_["age_s"] is not None else None
    st_["pause_requested"] = os.path.exists(os.path.join(RUNS, branch, "PAUSE"))
    # Fallbacks, so a run that stopped before the trainer wrote these fields (or that is
    # not running at all, which is exactly when you want the disk figure) still shows them.
    if st_.get("disk_mb") is None:
        st_["disk_mb"] = round(dir_mb(os.path.join(RUNS, branch)), 1)
    if not st_.get("eval"):
        ev = evals(branch)
        st_["eval"] = ev.iloc[-1].to_dict() if not ev.empty else {}
    if not st_.get("next_eval_update") and st_.get("update") is not None:
        n = max(1, int(branch_cfg(branch).get("eval_every", 10)))
        st_["next_eval_update"] = st_["update"] + (n - st_["update"] % n)
    return st_


def dir_mb(path: str) -> float:
    total = 0
    for root, _dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total / (1024 * 1024)


def why_it_died(s: dict, branch: str) -> tuple[str, str]:
    """(headline, detail) for a run that is not running. A trainer that raises writes
    its own reason; a trainer the kernel killed writes nothing at all, so the last
    heartbeat before the kill has to be read as evidence."""
    if s.get("error"):
        return s["error"], s.get("traceback", "")
    if s["state"] != "dead":
        return "", ""
    used, free = s.get("total_mb"), s.get("free_mb")
    hint = ("The process vanished without writing a reason — that is what an OOM kill "
            "(or `kill -9`) looks like from here. ")
    if used:
        hint += f"Its last heartbeat reported {used:.0f} MB in use"
        if free is not None:
            hint += f" with {free:.0f} MB free on the machine"
        hint += (". Set mem_limit_mb in the config below that ceiling and the run will "
                 "checkpoint and exit cleanly instead.")
    return "no exit record — the process was killed from outside", hint + "\n\n" + log_tail(branch, 30)


def read_pid(path: str) -> int:
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return -1


def log_tail(name: str, n: int = 12) -> str:
    path = os.path.join(RUNS, f"{name}.log")
    if not os.path.exists(path):
        return ""
    with open(path, "rb") as f:
        f.seek(max(0, os.path.getsize(path) - 6000))
        return "\n".join(f.read().decode("utf-8", "replace").splitlines()[-n:])


def pct(v) -> str:
    """A missing win rate reads as an em dash, never as "nan%" — an eval row read back
    from the log has NaN wherever that opponent's games failed."""
    if v is None or (isinstance(v, float) and v != v) or pd.isna(v):
        return "—"
    return f"{float(v):.0%}"


def live_card(b: str) -> None:
    """What the trainer is doing right now — the answer to "is it even running?"."""
    s = status(b)
    state = s["state"]
    role = STATE_STYLE.get(state, "")
    age = f"{s['age_s']:.0f}s ago" if s.get("age_s") is not None else "no heartbeat yet"
    stale = state == "running" and s["age_s"] > 300
    flags = ""
    if stale:
        flags += " " + pill("heartbeat stale", "warning")
    if s.get("pause_requested") and state == "running":
        flags += " " + pill("pause requested", "warning")
    # Name and state on one line, the run's vitals beneath it — the colour of the state
    # pill repeats the word inside it, so it is never the only carrier of the meaning.
    st.markdown(
        f'<div class="rlm-card"><h3 style="margin:0 0 6px 0">{b} '
        f'{pill(state, role)}{flags}</h3>'
        f'<span class="rlm-sub">step <b>{s.get("step", "—"):,}</b> · update '
        f'<b>{s.get("update", "—")}</b> · matches <b>{s.get("matches", "—")}</b> · phase '
        f'<b>{s.get("phase", "—")}</b> · heartbeat {age}</span></div>'
        if isinstance(s.get("step"), int) else
        f'<div class="rlm-card"><h3 style="margin:0 0 6px 0">{b} '
        f'{pill(state, role)}{flags}</h3>'
        f'<span class="rlm-sub">no progress recorded yet · heartbeat {age}</span></div>',
        unsafe_allow_html=True)

    ev = s.get("eval") or {}
    cols = st.columns(5)
    cols[0].metric("win vs HARD", pct(ev.get("winrate_hard")),
                   help="the graduation opponent (§8.2); 0.55 is the reference bar")
    cols[1].metric("loss vs HARD", pct(ev.get("lossrate_hard")))
    # Win/loss/draw read as one triple: on town a draw means the round cap was reached
    # with the unit counts level, so it is the midpoint between the other two, not a
    # separate outcome to hunt for.
    cols[2].metric("draw vs HARD", pct(ev.get("drawrate_hard")),
                   help="round cap reached with equal living units; stalls count here too")
    cols[3].metric("memory", f"{s['total_mb']:.0f} MB" if s.get("total_mb") else "—",
                   help="trainer + its Godot envs; `free` is what the machine has left")
    cols[4].metric("run on disk", f"{s['disk_mb']:.0f} MB" if s.get("disk_mb") is not None else "—")
    if pct(ev.get("winrate_hard")) == "—":
        nxt = s.get("next_eval_update")
        st.caption("No evaluation yet — win rates appear after the first one"
                   + (f" (update {nxt}; currently at {s.get('update', 0)})." if nxt else ".")
                   + " A run now evaluates on its first update too, so this should not stay"
                     " blank for long; lower `eval_every` to see it sooner.")
    else:
        stall = ev.get("stallrate_hard") or 0
        if stall >= 0.25:
            st.caption(f"{stall:.0%} of the last evaluation's games ended on the step cap "
                       f"(`max_steps`) — the greedy policy stalls on a free action instead of "
                       f"ending its turn, so those games say little about either opponent. "
                       f"If NORMAL and HARD also read identical, the stall is swallowing the "
                       f"whole evaluation; expect this to fall as the policy learns to end a turn.")
    if s.get("free_mb") is not None:
        st.caption(f"machine: {s['free_mb']:.0f} MB free ({s.get('machine_pct', 0):.0f}% used)"
                   + (f" · envs {s['envs_mb']:.0f} MB · trainer {s['rss_mb']:.0f} MB"
                      if "envs_mb" in s else ""))

    act = s.get("activity", "")
    if state == "running" and act:
        if s.get("total"):
            st.progress(min(1.0, s["done"] / s["total"]),
                        text=f"{act}: {s['done']}/{s['total']}"
                             + (f" · {s['env_steps_per_sec']:.1f} env steps/s" if "env_steps_per_sec" in s else "")
                             + (f" · buffer {s['buffer_mb']:.0f} MB" if "buffer_mb" in s else "")
                             + (f" · env rounds {s['rounds']}" if s.get("rounds") else "")
                             # An evaluation batch runs for minutes; "which round is each
                             # game on" is the difference between slow and stuck.
                             + (f" · games at round {s['eval_rounds']}" if s.get("eval_rounds") else "")
                             + (f" / {s['eval_steps']} steps" if s.get("eval_steps") else ""))
        else:
            st.caption(act)
    elif state == "paused":
        st.info(f"Paused at update {s.get('update', '—')}. The Godot envs are still up, "
                f"so Continue restarts training within a couple of seconds.")

    if state in ("dead", "crashed"):
        headline, detail = why_it_died(s, b)
        st.error(f"**{b} is not running.** {headline or 'no reason recorded'}")
        if detail:
            with st.expander("what happened", expanded=True):
                st.code(detail)
    with st.expander("log tail", expanded=state in ("dead", "crashed")):
        st.code(log_tail(b) or "(empty)")


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
        df = pd.DataFrame({"step": [e.step for e in ev], tag: [e.value for e in ev]})
        # One step can carry two values for a tag: a resume replays steps it already
        # logged, and an evaluation re-run writes the same global_step again. Charting
        # then fails outright ("Reindexing only valid with uniquely valued Index"),
        # because concat aligns the tags on a non-unique index. Newest wins.
        out[tag] = df.drop_duplicates("step", keep="last").sort_values("step")
    return out


def tb_stamp(branch: str) -> float:
    files = glob.glob(os.path.join(RUNS, branch, "tb", "events.*"))
    return max((os.path.getmtime(f) for f in files), default=0.0)


def jsonl(path: str) -> pd.DataFrame:
    rows = []
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass       # a line half-written when we read it; it will be there next time
    return pd.DataFrame(rows)


def evals(branch: str) -> pd.DataFrame:
    """One row per evaluation, both opponents side by side (eval_log.jsonl)."""
    return jsonl(os.path.join(RUNS, branch, "eval_log.jsonl"))


def eval_games(branch: str) -> pd.DataFrame:
    """One row per evaluation GAME (eval_games.jsonl) — what the aggregates are made of.

    Only runs from the version that writes it have this; older branches fall back to the
    aggregates, which is why every caller has to cope with an empty frame."""
    df = jsonl(os.path.join(RUNS, branch, "eval_games.jsonl"))
    if not df.empty:
        df["branch"] = branch
        df["when"] = pd.to_datetime(df["time"], unit="s")
        # Same filter as long_evals, so the games shown belong to the tests shown.
        want = [str(o).lower() for o in
                (branch_cfg(branch).get("eval_opponents") or DEFAULT_EVAL_OPPONENTS)]
        keep = df[df["opponent"].str.lower().isin(want)]
        if not keep.empty:
            df = keep
    return df


def long_evals(branch: str) -> pd.DataFrame:
    """eval_log.jsonl unpivoted to one row per (evaluation, opponent) — the natural shape
    for "show me each test separately", and what every chart on the page reads."""
    ev = evals(branch)
    if ev.empty:
        return ev
    # Which opponents to show: what the branch's config asks for, intersected with what
    # is actually in the log. The intersection matters both ways — a branch evaluated
    # against NORMAL before `eval_opponents` narrowed to HARD still has those columns on
    # disk, and showing them would put a stale, retired measurement next to a live one.
    # The jsonl keeps the history either way.
    found = sorted({c.rsplit("_", 1)[1] for c in ev.columns if c.startswith("winrate_")})
    want = [str(o).lower() for o in
            (branch_cfg(branch).get("eval_opponents") or DEFAULT_EVAL_OPPONENTS)]
    opponents = [o for o in found if o in want] or found
    out = []
    for opp in opponents:
        cols = {c: c[: -len(opp) - 1] for c in ev.columns if c.endswith(f"_{opp}")}
        if not cols:
            continue
        d = ev[["step", "update", "time", "phase", "stage"] + list(cols)].rename(columns=cols)
        d["opponent"] = opp.upper()
        out.append(d)
    if not out:
        return pd.DataFrame()
    df = pd.concat(out, ignore_index=True).sort_values(["step", "opponent"])
    df["when"] = pd.to_datetime(df["time"], unit="s")
    return df


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
                               win_hard=e.get("winrate_hard"), loss_hard=e.get("lossrate_hard"),
                               draw_hard=e.get("drawrate_hard"), rounds_hard=e.get("rounds_hard"),
                               value_diff_hard=e.get("value_diff_hard"))
            rows.append(row)
    cols = ["branch", "step", "update", "matches", "phase", "stage", "opponent", "maps", "n_envs",
            "eval_step", "win_hard", "loss_hard", "draw_hard", "rounds_hard", "value_diff_hard",
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

def tidy(sc: dict, tags: list[str], names: dict[str, str] | None = None) -> pd.DataFrame:
    """TensorBoard frames -> long form (step, series, value), for Altair."""
    out = []
    for t in tags:
        if t not in sc or sc[t].empty:
            continue
        d = sc[t].rename(columns={t: "value"}).copy()
        d["series"] = (names or {}).get(t, t.split("/", 1)[-1])
        out.append(d[["step", "series", "value"]])
    return pd.concat(out, ignore_index=True) if out else pd.DataFrame()


def line_chart(df: pd.DataFrame, title: str, *, pct: bool = False, height: int = 230,
               order: list[str] | None = None, x: str = "step", x_title: str = "env steps"):
    """Multi-series line with a hover crosshair and a legend.

    Series keep their colour by NAME, not by position, so filtering one out never
    repaints the others. Colours come from the fixed slot order in SERIES."""
    if df.empty:
        return None
    names = order or sorted(df["series"].unique())
    scale = alt.Scale(domain=names, range=SERIES[:len(names)])
    fmt = ".0%" if pct else "~s"
    hover = alt.selection_point(fields=[x], nearest=True, on="mouseover", empty=False)
    enc_y = alt.Y("value:Q", title=None, axis=alt.Axis(format=fmt),
                  scale=alt.Scale(domain=[0, 1]) if pct else alt.Scale(zero=False))
    single = len(names) == 1
    base = alt.Chart(df).encode(
        x=alt.X(f"{x}:Q", title=x_title, axis=alt.Axis(format="~s")), y=enc_y,
        color=alt.Color("series:N", scale=scale,
                        legend=None if single else alt.Legend(title=None, orient="top")))
    line = base.mark_line(strokeWidth=2, interpolate="monotone")
    pts = base.mark_circle(size=64, opacity=0).add_params(hover)
    dots = base.mark_circle(size=64).transform_filter(hover)
    rule = (alt.Chart(df).mark_rule(color=GRID, strokeWidth=1)
            .encode(x=f"{x}:Q",
                    tooltip=[alt.Tooltip(f"{x}:Q", title=x_title, format="~s"),
                             alt.Tooltip("series:N", title=""),
                             alt.Tooltip("value:Q", format=".3f")])
            .transform_filter(hover))
    layered = alt.layer(line, pts, rule, dots, title=title).properties(height=height)
    return layered.configure_view(stroke=None).configure_axis(
        grid=True, gridColor=GRID, gridOpacity=0.4, domainColor=GRID, tickColor=GRID,
        labelColor=INK_DIM, titleColor=INK_DIM, labelFontSize=11, titleFontSize=11,
        titleFontWeight="normal"
    ).configure_legend(labelColor=INK, titleColor=INK_DIM, labelFontSize=11,
                       symbolType="stroke", symbolStrokeWidth=3
    ).configure_title(color=INK, fontSize=13, fontWeight=600, anchor="start")


def stacked_area(df: pd.DataFrame, title: str, order: list[str], colors: dict[str, str],
                 height: int = 230, x: str = "step", x_title: str = "env steps"):
    """Composition over time as shares. A 2px surface-coloured gap separates the bands so
    adjacent fills never blend into one another."""
    if df.empty:
        return None
    present = [o for o in order if o in set(df["series"])]
    scale = alt.Scale(domain=present, range=[colors[o] for o in present])
    ch = (alt.Chart(df).mark_area(interpolate="monotone", line=False,
                                  stroke=SURFACE, strokeWidth=2)
          .encode(x=alt.X(f"{x}:Q", title=x_title, axis=alt.Axis(format="~s")),
                  y=alt.Y("value:Q", stack="normalize", title=None,
                          axis=alt.Axis(format=".0%")),
                  color=alt.Color("series:N", scale=scale, sort=present,
                                  legend=alt.Legend(title=None, orient="top")),
                  order=alt.Order("order:Q"),
                  tooltip=[alt.Tooltip(f"{x}:Q", title=x_title, format="~s"),
                           alt.Tooltip("series:N", title="outcome"),
                           alt.Tooltip("value:Q", title="games")])
          .properties(height=height, title=title))
    return ch.configure_view(stroke=None).configure_axis(
        grid=False, domainColor=GRID, tickColor=GRID, labelColor=INK_DIM,
        titleColor=INK_DIM, labelFontSize=11, titleFontSize=11, titleFontWeight="normal"
    ).configure_legend(labelColor=INK, titleColor=INK_DIM, labelFontSize=11
    ).configure_title(color=INK, fontSize=13, fontWeight=600, anchor="start")


def show(ch) -> None:
    if ch is not None:
        st.altair_chart(ch, width="stretch")


def chart(sc: dict, tags: list[str], title: str, *, pct: bool = False,
          names: dict[str, str] | None = None) -> None:
    show(line_chart(tidy(sc, tags, names), title, pct=pct))


def behaviour(sc: dict) -> None:
    """What the policy is actually *doing*, over time — not just how well it scores.

    This panel exists because of a real miss: town-1 spent five hours converging on
    `move_held` (75% of its actions, `end` at 0.4%) and every score chart looked merely
    flat. A share-of-actions trend makes that unmistakable — one band swallowing the
    plot is a collapsed policy, whatever the loss curves say."""
    kinds = {t[len("usage/kind_"):]: d for t, d in sc.items() if t.startswith("usage/kind_")}
    units = {t[len("usage/unit_"):]: d for t, d in sc.items() if t.startswith("usage/unit_")}
    if not kinds and not units:
        return
    st.markdown("#### What the policy is doing")

    def drift(series: dict[str, pd.DataFrame], title: str, top: int = 5):
        """Top-N by latest share, everything else folded into one band — a new hue is
        never generated for a 9th series."""
        if not series:
            return None
        latest = {k: float(d.iloc[-1, 1]) for k, d in series.items()}
        keep = [k for k, _ in sorted(latest.items(), key=lambda kv: -kv[1])[:top]]
        rows = []
        for k, d in series.items():
            name = k if k in keep else "other"
            rows.append(d.rename(columns={d.columns[1]: "value"})[["step", "value"]]
                        .assign(series=name))
        df = (pd.concat(rows, ignore_index=True)
              .groupby(["step", "series"], as_index=False)["value"].sum())
        order = keep + (["other"] if (df["series"] == "other").any() else [])
        df["order"] = df["series"].map({o: i for i, o in enumerate(order)})
        colors = dict(zip(order, SERIES))
        return stacked_area(df, title, order, colors, height=250)

    c1, c2 = st.columns(2)
    with c1:
        show(drift(kinds, "share of actions, by intent kind"))
        if kinds:
            top = sorted(((float(d.iloc[-1, 1]), k) for k, d in kinds.items()), reverse=True)
            share, name = top[0]
            ends = float(kinds["end"].iloc[-1, 1]) if "end" in kinds else 0.0
            if share >= 0.5:
                st.markdown(
                    f'{pill("collapsed", "critical")} <span class="rlm-sub">'
                    f'<b>{share:.0%}</b> of actions are <b>{name}</b> and only '
                    f'<b>{ends:.1%}</b> end a turn — the policy has found a loop rather '
                    f'than a strategy.</span>', unsafe_allow_html=True)
            elif share >= 0.35:
                st.markdown(
                    f'{pill("narrowing", "warning")} <span class="rlm-sub">'
                    f'<b>{share:.0%}</b> of actions are <b>{name}</b>. Worth watching.'
                    f'</span>', unsafe_allow_html=True)
    with c2:
        show(drift(units, "share of actions, by unit type"))


def controls(b: str, s: dict, key: str = "") -> None:
    """Start / pause / continue / stop for one branch (11.3).

    Pause and Stop are different things and the labels say so: Stop ends the process
    (Start is then a fresh `resume` from the last checkpoint, a minute of Godot boot),
    while Pause leaves it alive with its envs warm and Continue picks up in seconds.
    """
    state = s.get("state")
    live = state in ("running", "paused")
    c1, c2, c3, c4 = st.columns(4)
    if state == "paused":
        if c1.button("Continue", key=f"cont{key}{b}", type="primary"):
            run_sh("continue", b)
    else:
        if c1.button("Pause", key=f"pause{key}{b}", disabled=state != "running",
                     help="checkpoint and hold; the Godot envs stay up"):
            run_sh("pause", b)
    if c2.button("Start", key=f"start{key}{b}", disabled=live,
                 help="resume from the latest checkpoint in a new process"):
        run_sh("resume", b)
    if c3.button("Stop", key=f"stop{key}{b}", disabled=not live,
                 help="checkpoint after this update, then exit"):
        run_sh("stop", b)
    if c4.button("Play vs latest", key=f"play{key}{b}"):
        play_vs(os.path.join(b, "latest.pt"))


def page_overview() -> None:
    st.header("Runs")

    @st.fragment(run_every=5)
    def live() -> None:
        bs = branches()
        if not bs:
            st.info("No runs yet — start one below.")
        for b in bs:
            live_card(b)
            controls(b, status(b), key="ov")
            st.divider()
    live()

    rows = []
    for b in branches():
        s = status(b)
        ev = evals(b)
        last = ev.iloc[-1] if not ev.empty else {}
        rows.append(dict(branch=b, state=s.get("state", "—"), step=s.get("step"),
                         update=s.get("update"), matches=s.get("matches"), phase=s.get("phase"),
                         stage=s.get("stage"),
                         win_hard=last.get("winrate_hard"),
                         loss_hard=last.get("lossrate_hard"),
                         draw_hard=last.get("drawrate_hard"),
                         stall_hard=last.get("stallrate_hard"),
                         mem_mb=round(s["total_mb"]) if s.get("total_mb") else None,
                         disk_mb=s.get("disk_mb"),
                         heartbeat_min=round(s["age_min"], 1) if s.get("age_min") is not None else None))
    if rows:
        st.dataframe(pd.DataFrame(rows), width="stretch", hide_index=True)

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

    @st.fragment(run_every=5)
    def head() -> None:
        live_card(b)
    head()

    @st.fragment(run_every=30)
    def live() -> None:
        sc = scalars(b, tb_stamp(b))
        if not sc:
            st.info("no curves yet — they appear after the first PPO update (one full rollout of "
                    f"{cfg.get('rollout_steps', '?')} × {cfg.get('n_envs', '?')} env steps)")
            return
        a, bcol = st.columns(2)
        with a:
            chart(sc, ["train/winrate_vs_ai", "train/winrate_vs_pool", "train/drawrate"],
                  "win / draw rate (training)", pct=True)
            chart(sc, ["eval/winrate_hard", "eval/stallrate_hard"],
                  "greedy eval vs HARD (0.55 is the §8.2 reference bar)", pct=True)
            chart(sc, ["train/value_diff_end"], "army-value differential at match end")
            chart(sc, ["train/match_rounds"], "match length (rounds)")
        with bcol:
            chart(sc, ["ppo/policy_loss", "ppo/value_loss"], "PPO losses")
            chart(sc, ["ppo/entropy", "ppo/approx_kl"], "entropy / KL")
            chart(sc, ["speed/env_steps_per_sec", "speed/update_secs"], "speed")
            chart(sc, ["speed/matches_done"], "matches completed (flat = episodes never end)")
        behaviour(sc)
    live()

    st.subheader("Controls")
    controls(b, s)

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
    if ev.empty:
        st.warning(
            f"**No evaluation has finished yet, so the win rates vs NORMAL and HARD are "
            f"blank.** A run evaluates on its first update and then every "
            f"`eval_every` ({cfg.get('eval_every', '?')}) updates — at update "
            f"{s.get('update', 0)} the next one lands at {s.get('next_eval_update', '?')}. "
            f"For a quicker read, lower `eval_every` and `eval_games` below, or run one "
            f"by hand:")
        st.code(f"python rl/train.py eval rl/runs/{b}/latest.pt --games 10 --opponent hard")
    else:
        ev = ev.copy()
        ev["time"] = pd.to_datetime(ev["time"], unit="s")
        st.dataframe(ev, width="stretch", hide_index=True)


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


def page_evaluations(b: str) -> None:
    """Every evaluation, broken out — the answer to "one win rate tells me nothing".

    Three depths, coarse to fine: the latest test per opponent, the trend of every test
    over the run, and the individual games behind any one of them. The outcome mix is
    first on purpose: a 0% win rate made of honest losses and a 0% made of stalls are
    different problems, and only the mix distinguishes them."""
    st.header(f"Evaluations — {b}")
    lg = long_evals(b)
    if lg.empty:
        cfg = branch_cfg(b)
        s = status(b)
        st.info(f"No evaluation has finished for **{b}** yet. A run tests itself on its "
                f"first update and then every `eval_every` "
                f"({cfg.get('eval_every', '?')}) updates — it is at update "
                f"{s.get('update', 0)}, next test at {s.get('next_eval_update', '?')}.")
        st.code(f"python rl/train.py eval rl/runs/{b}/latest.pt --games 10 --opponent hard")
        return

    latest = lg[lg["step"] == lg["step"].max()]
    st.markdown(f"#### Latest test · step {int(lg['step'].max()):,}")
    for _, r in latest.iterrows():
        cols = st.columns(6)
        cols[0].metric(f"{r['opponent']} · win", pct(r.get("winrate")))
        cols[1].metric("loss", pct(r.get("lossrate")))
        cols[2].metric("draw", pct(r.get("drawrate")))
        cols[3].metric("stalled", pct(r.get("stallrate")))
        cols[4].metric("value diff", f"{r['value_diff']:+.2f}" if pd.notna(r.get("value_diff")) else "—")
        cols[5].metric("rounds", f"{r['rounds']:.1f}" if pd.notna(r.get("rounds")) else "—")

    games = eval_games(b)
    st.divider()

    # --- outcome mix, per opponent -----------------------------------------------------
    st.markdown("#### How the games ended")
    if not games.empty:
        mix = (games.groupby(["step", "opponent", "result"]).size()
               .reset_index(name="value").rename(columns={"result": "series"}))
        mix["order"] = mix["series"].map({o: i for i, o in enumerate(OUTCOME_ORDER)}).fillna(9)
        cols = st.columns(len(mix["opponent"].unique()))
        for col, opp in zip(cols, sorted(mix["opponent"].unique())):
            with col:
                show(stacked_area(mix[mix["opponent"] == opp], f"vs {opp.upper()}",
                                  OUTCOME_ORDER, OUTCOME_COLOR))
    else:
        # Older branches have the rates but not the per-game rows.
        show(line_chart(
            pd.concat([lg.assign(series=lg["opponent"] + " · " + k, value=lg[k])
                       for k in ("winrate", "drawrate", "stallrate") if k in lg],
                      ignore_index=True)[["step", "series", "value"]],
            "outcome rates (per-game detail starts with the next evaluation)", pct=True))

    # --- trends ------------------------------------------------------------------------
    st.markdown("#### Every test over the run")
    c1, c2 = st.columns(2)
    with c1:
        show(line_chart(lg.rename(columns={"opponent": "series", "winrate": "value"})
                        [["step", "series", "value"]],
                        "win rate (0.55 vs NORMAL is the §8.2 graduation bar)", pct=True))
        show(line_chart(lg.rename(columns={"opponent": "series", "value_diff": "value"})
                        [["step", "series", "value"]],
                        "army-value differential at the end"))
    with c2:
        if "stallrate" in lg:
            show(line_chart(lg.rename(columns={"opponent": "series", "stallrate": "value"})
                            [["step", "series", "value"]],
                            "stalled on the step cap (should fall to zero)", pct=True))
        show(line_chart(lg.rename(columns={"opponent": "series", "rounds": "value"})
                        [["step", "series", "value"]], "match length (rounds)"))

    # --- the tests themselves ----------------------------------------------------------
    st.markdown("#### Test log")
    cols = [c for c in ("step", "update", "opponent", "games", "winrate", "lossrate",
                        "drawrate", "stallrate", "value_diff", "rounds", "when") if c in lg]
    tbl = lg[cols].sort_values(["step", "opponent"], ascending=[False, True])
    sel = st.dataframe(tbl, width="stretch", hide_index=True, on_select="rerun",
                       selection_mode="single-row",
                       column_config={c: st.column_config.NumberColumn(format="%.2f")
                                      for c in ("winrate", "lossrate", "drawrate",
                                                "stallrate", "value_diff", "rounds")
                                      if c in cols})
    rows = sel.get("selection", {}).get("rows", []) if isinstance(sel, dict) else sel.selection.rows

    st.markdown("#### Individual games")
    if games.empty:
        st.caption("Per-game rows start with the next evaluation this trainer runs "
                   "(`eval_games.jsonl`). Until then only the aggregates above exist.")
        return
    if rows:
        pick = tbl.iloc[rows[0]]
        g = games[(games["step"] == pick["step"])
                  & (games["opponent"].str.upper() == pick["opponent"])]
        st.caption(f"step {int(pick['step']):,} vs {pick['opponent']} — "
                   f"{len(g)} games. Clear the selection above to see every game.")
    else:
        g = games
        st.caption(f"all {len(g)} games across every evaluation; select a test above to narrow.")
    gc = [c for c in ("step", "opponent", "game", "result", "by", "value_diff", "rounds",
                      "steps", "illegal", "map", "side", "seed", "when") if c in g]
    st.dataframe(g[gc].sort_values(["step", "opponent", "game"], ascending=[False, True, True]),
                 width="stretch", hide_index=True)
    st.download_button("Download games CSV", g[gc].to_csv(index=False).encode(),
                       f"{b}_eval_games.csv", "text/csv")


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
    sel = st.dataframe(v.drop(columns=["file"]), width="stretch", hide_index=True,
                       on_select="rerun", selection_mode="single-row")
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
                             trend="improving" if slope > 0 else "regressing" if slope < 0 else "flat"))
            series[f"{b} · {mp}"] = df.set_index("step")[tag]   # no ":" — Altair reads it as a type hint
    if not rows:
        st.info("no per-map data yet")
        return
    st.dataframe(pd.DataFrame(rows).sort_values(["map", "branch"]), width="stretch", hide_index=True)
    st.caption("training win rate per map, per branch")
    st.line_chart(pd.concat(series, axis=1).sort_index(), height=300)


def main() -> None:
    gate()
    st.markdown(THEME_CSS, unsafe_allow_html=True)
    st.sidebar.title("Isotope RLM")
    bs = branches()
    page = st.sidebar.radio(
        "Page", ["Overview", "Branch", "Evaluations", "Checkpoints", "Replays", "Maps"])
    per_branch = page in ("Branch", "Evaluations")
    chosen = st.sidebar.selectbox("Branch", bs) if (per_branch and bs) else None
    if st.sidebar.button("Refresh data"):
        st.cache_data.clear()
        st.rerun()
    if st.sidebar.button("Sign out"):
        _sign_out(st.session_state.get("auth_token"))
        st.rerun()
    st.sidebar.caption(f"runs: `{RUNS}`\n\nGodot: `{godot_bin()}`")
    if per_branch and not bs:
        st.info("no runs yet")
    elif page == "Overview":
        page_overview()
    elif page == "Branch":
        page_branch(chosen)
    elif page == "Evaluations":
        page_evaluations(chosen)
    elif page == "Checkpoints":
        page_checkpoints()
    elif page == "Replays":
        page_replays()
    else:
        page_maps()


main()
