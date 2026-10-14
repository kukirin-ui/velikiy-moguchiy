"""python3 -m pytest tools/test_text_review.py"""
import json
import subprocess
import sys
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import text_review as t  # noqa: E402

DIFF = """diff --git a/PRIVACY.md b/PRIVACY.md
--- a/PRIVACY.md
+++ b/PRIVACY.md
@@ -10,3 +10,4 @@ head
 Контекст.
-Старая строка.
+Пишите [куда писать].
+Вторая новая строка.
 Хвост.
@@ -40,2 +41,2 @@
 Без добавлений.
-Удалено.
"""


def test_reviewable_files():
    assert t.reviewable("PRIVACY.md")
    assert t.reviewable("docs/notes.txt")
    assert t.reviewable(".github/ISSUE_TEMPLATE/problem.yml")
    assert not t.reviewable(".github/workflows/tests.yml")
    assert not t.reviewable("lipread/phrases_ru.txt")
    assert not t.reviewable("mac/velikiy-moguchiy-core/resources/dictionary-it-ru.txt")
    assert not t.reviewable("mac/vendor/lipflow/README.md")
    assert not t.reviewable("THIRD_PARTY.md")
    assert not t.reviewable("tools/text_review/prompt.md")
    assert not t.reviewable("tools/privacy_guard.py")


def test_parse_diff_keeps_new_line_numbers_and_skips_pure_deletions():
    secs = t.parse_diff("PRIVACY.md", DIFF)
    assert len(secs) == 1
    assert secs[0].added == {11, 12}
    assert [no for no, _, _ in secs[0].lines] == [10, 11, 12, 13]
    assert "+   11| Пишите [куда писать]." in secs[0].render()


def test_chunks_split_long_sections():
    sec = t.Section("a.md", [(i, True, "слово " * 50) for i in range(1, 200)])
    parts = t.chunks([sec], limit=4000)
    assert len(parts) > 1
    assert all(len("".join(s.render() for s in c)) <= 4200 for c in parts)
    assert sorted(no for c in parts for s in c for no in s.added) == list(range(1, 200))


def finding_reply(**kw):
    item = {"file": "PRIVACY.md", "line": 11, "severity": "high", "category": "placeholder",
            "quote": "[куда писать]", "problem": "Незаполненное место.", "fix": "Указать issues."}
    item.update(kw)
    return json.dumps({"findings": [item]})


def test_parse_findings_only_for_added_lines():
    chunk = t.parse_diff("PRIVACY.md", DIFF)
    assert len(t.parse_findings(finding_reply(), chunk)) == 1
    assert t.parse_findings(finding_reply(line=10), chunk) == []
    assert t.parse_findings(finding_reply(file="other.md"), chunk) == []
    assert t.parse_findings(finding_reply(severity="critical"), chunk) == []


def test_reply_wrapped_in_a_code_fence():
    chunk = t.parse_diff("PRIVACY.md", DIFF)
    reply = "Вот результат:\n```json\n" + finding_reply() + "\n```"
    assert len(t.parse_findings(reply, chunk)) == 1


def test_reply_with_a_stray_bracket_still_yields_its_findings():
    chunk = t.parse_diff("PRIVACY.md", DIFF)
    broken = finding_reply()[:-1] + "]}"
    assert broken.endswith("}]]}")
    assert len(t.parse_findings(broken, chunk)) == 1
    two = json.dumps({"findings": [json.loads(finding_reply())["findings"][0]] * 2})[:-1] + "]}"
    assert len(t.parse_findings(two, chunk)) == 2
    assert t.parse_findings('{"findings": []}', chunk) == []


def test_model_output_is_sanitised():
    chunk = t.parse_diff("PRIVACY.md", DIFF)
    f = t.parse_findings(finding_reply(problem="пинг @someone <script>\nи ещё"), chunk)[0]
    assert "@​someone" in f.problem and "<" not in f.problem and "\n" not in f.problem


def test_allowlist(tmp_path):
    p = tmp_path / "allow.txt"
    p.write_text("# comment\n* | zigansh1n | public account\ndocs/*.md | черновик релиза | GitHub term\n")
    rules = t.load_allowlist(p)
    assert t.allowed(t.Finding("README.md", 1, "high", "personal-data", "автор zigansh1n", ""), rules)
    assert t.allowed(t.Finding("docs/a.md", 1, "high", "draft", "создаёт черновик релиза", ""), rules)
    assert not t.allowed(t.Finding("PRIVACY.md", 1, "high", "draft", "создаёт черновик релиза", ""), rules)
    assert "public account" in t.system_prompt(rules)


def test_repo_allowlist_and_prompt_load():
    rules = t.load_allowlist()
    assert rules
    assert "{{ALLOWLIST}}" not in t.system_prompt(rules)


def test_api_errors_are_unavailable(monkeypatch):
    monkeypatch.setattr(t, "ENDPOINT", "https://llm.example/v1/chat/completions")
    def refuse(*a, **kw):
        raise urllib.error.HTTPError(t.ENDPOINT, 403, "Forbidden", {}, None)
    monkeypatch.setattr(t.urllib.request, "urlopen", refuse)
    try:
        t.ask("s", "u", "token")
    except t.Unavailable as e:
        assert "403" in str(e)
    else:
        raise AssertionError("expected Unavailable")
    class Plain:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b"OK"
    monkeypatch.setattr(t.urllib.request, "urlopen", lambda *a, **kw: Plain())
    try:
        t.ask("s", "u", "token")
    except t.Unavailable as e:
        assert "without a chat completion" in str(e)
    else:
        raise AssertionError("expected Unavailable")
    chunk = t.parse_diff("PRIVACY.md", DIFF)
    try:
        t.parse_findings("not json", chunk)
    except t.Unavailable:
        pass
    else:
        raise AssertionError("expected Unavailable")


def make_repo(tmp_path):
    def run(*args):
        subprocess.run(["git", *args], cwd=tmp_path, check=True, capture_output=True)
    run("init", "-q", "-b", "main")
    run("config", "user.email", "1+dev@users.noreply.github.com")
    run("config", "user.name", "dev")
    (tmp_path / "PRIVACY.md").write_text("Строка.\n")
    run("add", ".")
    run("commit", "-q", "-m", "base")
    (tmp_path / "PRIVACY.md").write_text("Строка.\nПишите [куда писать].\n")
    (tmp_path / "code.py").write_text("x = 1\n")
    run("add", ".")
    run("commit", "-q", "-m", "head")
    return "HEAD~1", "HEAD"


def test_main_fails_on_high_and_passes_when_unavailable(tmp_path, monkeypatch, capsys):
    base, head = make_repo(tmp_path)
    monkeypatch.setattr(t, "ROOT", tmp_path)
    monkeypatch.setattr(t, "PAUSE", 0)
    monkeypatch.setattr(t, "ENDPOINT", "https://llm.example/v1/chat/completions")
    monkeypatch.setattr(t, "MODEL", "some-model")
    monkeypatch.setenv("TEXT_REVIEW_TOKEN", "x")
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)

    monkeypatch.setattr(t, "ask", lambda s, u, tok: finding_reply(line=2))
    assert t.main(["--base", base, "--head", head]) == 1
    out = capsys.readouterr().out
    assert "::error file=PRIVACY.md,line=2" in out

    monkeypatch.setattr(t, "ask", lambda s, u, tok: finding_reply(line=2, severity="medium"))
    assert t.main(["--base", base, "--head", head]) == 0

    def down(*a):
        raise t.Unavailable("HTTP 429")
    monkeypatch.setattr(t, "ask", down)
    assert t.main(["--base", base, "--head", head]) == 0
    assert "::warning" in capsys.readouterr().out


def test_main_without_texts(tmp_path, monkeypatch, capsys):
    base, head = make_repo(tmp_path)
    (tmp_path / "PRIVACY.md").unlink()
    monkeypatch.setattr(t, "ROOT", tmp_path)
    assert t.main(["--base", head, "--head", head]) == 0
    assert "no changed texts" in capsys.readouterr().out


def test_main_without_a_configured_model(tmp_path, monkeypatch, capsys):
    base, head = make_repo(tmp_path)
    monkeypatch.setattr(t, "ROOT", tmp_path)
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
    monkeypatch.setattr(t, "ask", lambda *a: (_ for _ in ()).throw(AssertionError("must not call the model")))
    for endpoint, model, token in (("", "m", "k"), ("https://llm.example", "", "k"), ("https://llm.example", "m", "")):
        monkeypatch.setattr(t, "ENDPOINT", endpoint)
        monkeypatch.setattr(t, "MODEL", model)
        monkeypatch.setenv("TEXT_REVIEW_TOKEN", token)
        assert t.main(["--base", base, "--head", head]) == 0
        assert "не настроена" in capsys.readouterr().out


def test_file_mode_reviews_every_line_and_fails_from_the_chosen_severity(tmp_path, monkeypatch, capsys):
    notes = tmp_path / "notes.md"
    notes.write_text("# Выпуск\n\n- Пишите [куда писать].\n")
    monkeypatch.setattr(t, "PAUSE", 0)
    monkeypatch.setattr(t, "ENDPOINT", "https://llm.example/v1/chat/completions")
    monkeypatch.setattr(t, "MODEL", "some-model")
    monkeypatch.setenv("TEXT_REVIEW_TOKEN", "x")
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
    sent = []

    def reply(system, user, token, severity="medium"):
        sent.append(user)
        return finding_reply(file=str(notes), line=3, severity=severity)
    monkeypatch.setattr(t, "ask", reply)
    assert t.main(["--file", str(notes)]) == 0
    assert "+    1| # Выпуск" in sent[0] and "+    3| - Пишите [куда писать]." in sent[0]
    assert t.main(["--file", str(notes), "--fail-on", "medium"]) == 1
    monkeypatch.setattr(t, "ask", lambda s, u, tok: finding_reply(file=str(notes), line=3, severity="low"))
    assert t.main(["--file", str(notes), "--fail-on", "medium"]) == 0
    capsys.readouterr()


FIXTURES = Path(__file__).resolve().parent / "text_review" / "fixtures"


def fixture(name):
    return (FIXTURES / f"{name}.json").read_bytes()


def test_recorded_reply_cut_off_by_the_default_token_limit():
    """Workers AI, gpt-oss-120b, no max_tokens: the reasoning used up 256 tokens and the answer stopped mid-JSON."""
    text, finish = t.reply_text(fixture("cut_off"))
    assert finish == "length" and text.startswith('{"findings"') and not text.rstrip().endswith("}")


def test_recorded_reply_with_a_stray_bracket_gives_the_finding():
    text, finish = t.reply_text(fixture("answered"))
    assert finish == "stop" and text.endswith("]]}")
    chunk = [t.Section("docs/AUTOMATION.md", [(361, True, ""), (362, True, "x")])]
    found = t.parse_findings(text, chunk)
    assert [(f.path, f.line, f.severity, f.category) for f in found] == [("docs/AUTOMATION.md", 362, "high", "placeholder")]


def test_reply_shapes():
    parts = {"choices": [{"message": {"content": [{"type": "text", "text": '{"findings"'}, {"type": "text", "text": ": []}"}]},
                          "finish_reason": "stop"}]}
    assert t.reply_text(json.dumps(parts).encode()) == ('{"findings": []}', "stop")
    nothing = {"choices": [{"message": {"content": None, "reasoning_content": "thinking"}, "finish_reason": "length"}]}
    assert t.reply_text(json.dumps(nothing).encode()) == ("", "length")
    native = {"result": {"response": '{"findings": []}'}, "success": True}
    assert t.reply_text(json.dumps(native).encode()) == ('{"findings": []}', None)


def test_a_cut_off_answer_is_retried_with_twice_the_limit(monkeypatch):
    limits = []

    def fake_post(body, token):
        limits.append(json.loads(body)["max_tokens"])
        return ('{"findings": []}', "stop") if len(limits) == 2 else ('{"findings": [', "length")
    monkeypatch.setattr(t, "post", fake_post)
    monkeypatch.setattr(t, "MAX_TOKENS", 1000)
    assert t.ask("s", "u", "token") == '{"findings": []}'
    assert limits == [1000, 2000]


def test_an_answer_that_stays_cut_off_is_unavailable_and_says_why(monkeypatch):
    monkeypatch.setattr(t, "post", lambda body, token: ("{", "length"))
    try:
        t.ask("s", "u", "token")
    except t.Unavailable as e:
        assert "cut off" in str(e) and "TEXT_REVIEW_MAX_TOKENS" in str(e)
    else:
        raise AssertionError("expected Unavailable")
