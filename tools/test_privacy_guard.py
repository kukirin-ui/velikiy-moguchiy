"""python3 -m pytest tools/test_privacy_guard.py"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import privacy_guard as g  # noqa: E402


def checks(rel, text, names=None):
    return {c for _, _, c in g.scan_text(rel, text, names or g.Names(()), [])}


def test_secrets_but_not_placeholders():
    assert checks("a.sh", "KEY=sk-" + "0123456789abcdef" * 2) == {"secret"}
    assert checks("a.sh", "KEY=sk-placeholder-not-a-real-key-000") == set()
    assert checks("a.py", "t = 'ghp_" + "A1" * 18 + "'") == {"secret"}
    assert checks("k", "-----BEGIN OPENSSH " + "PRIVATE KEY-----") == {"secret"}


def test_home_folders():
    assert checks("a.md", "see /Users/" + "someone/project") == {"path"}
    assert checks("a.md", "/Users/Shared/x and /home/runner/work and $HOME") == set()


def test_email_outside_notices():
    assert checks("a.md", "write to a.person@" + "mail.ru") == {"email"}
    assert checks("LICENSE", "Copyright a.person@" + "mail.ru") == set()
    assert checks("a.md", "icon@2x.png, 1+x@users.noreply.github.com, noreply@x.org, u@evil.example") == set()


def test_names_by_hash_any_form():
    names = g.Names(((g.digest("тестов"), 6, None, "name"), (g.digest("zz"), 2, 1, "name")))
    assert checks("a.md", "у Тестова и тестовой", names) == {"name"}
    assert checks("a.md", "@SomeTestovChannel", g.Names(((g.digest("testov"), 6, None, "name"),))) == {"name"}
    assert checks("a.md", "zz zza", names) == {"name"}
    assert checks("a.md", "zzzz azz", names) == set()


def test_data_lists_and_media(tmp_path, monkeypatch):
    monkeypatch.setattr(g, "ROOT", tmp_path)
    ids = "\n".join(f"Ab{i:02d}cdEfgH{i % 10}\t@ch" for i in range(25))
    (tmp_path / "list.tsv").write_text(ids)
    (tmp_path / "ok.md").write_text("plain")
    found = {(p, c) for p, _, c in g.scan(["list.tsv", "ok.md", "design/a.png", "ios/App/face.jpg",
                                           "lipread/newdata/queue_x.txt"], False, [])}
    assert ("list.tsv", "data-list: 25 video ids") in found
    assert ("ios/App/face.jpg", "media outside the UI and design folders") in found
    assert ("lipread/newdata/queue_x.txt", "data-list: file name") in found
    assert not any(p in ("ok.md", "design/a.png") for p, _ in found)


def test_commit_trailers():
    assert g.TRAILER.search("x\n\nCo-Authored-By: Claude <noreply@anthropic.com>")
    assert g.TRAILER.search("Generated with [Claude Code](https://claude.com/claude-code)")
    assert not g.TRAILER.search("Co-Authored-By: zigansh1n <1+zigansh1n@users.noreply.github.com>")


SIGNOFF = "Signed-off-by: dependabot[bot] <support@" + "github.com>"


def test_commit_people(tmp_path, monkeypatch):
    import subprocess

    def commit(msg, author, committer):
        env = {"GIT_AUTHOR_NAME": author[0], "GIT_AUTHOR_EMAIL": author[1],
               "GIT_COMMITTER_NAME": committer[0], "GIT_COMMITTER_EMAIL": committer[1], "PATH": "/usr/bin:/bin"}
        subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", msg], cwd=tmp_path, env=env, check=True)

    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    me = ("dev", "1+dev@users.noreply.github.com")
    commit("root", me, me)
    commit("ok", me, ("GitHub", "noreply@github.com"))
    commit("leaky committer", me, ("dev", "dev.person@" + "mail.ru"))
    commit("bump\n\n" + SIGNOFF, me, ("GitHub", "noreply@github.com"))
    commit("ai author", ("Claude", "noreply@" + "anthropic.com"), me)
    monkeypatch.setattr(g, "ROOT", tmp_path)
    found = {(subject, check) for subject, _, check in g.scan_commits("HEAD~4..HEAD", g.Names(()))}
    assert {check for _, check in found} == {"email", "ai-author"}
    assert len({subject for subject, _ in found}) == 2


def test_dependabot_signoff_only_exactly():
    assert g.DEPENDABOT_SIGNOFF.search("bump\n\n" + SIGNOFF)
    assert not g.DEPENDABOT_SIGNOFF.search("Signed-off-by: dependabot[bot] <someone@" + "mail.ru>")
    assert not g.DEPENDABOT_SIGNOFF.search("Signed-off-by: someone <support@" + "github.com>")


def doc_checks(rel, text):
    return {c for _, _, c in g.scan_doc(rel, text)} if g.is_doc(rel) else set()


def test_draft_markers():
    assert doc_checks("PRIVACY.md", "# Политика (ЧЕРНОВИК)\n\nТекст.") == {"draft"}
    assert doc_checks("a.md", "# Заголовок\n\n> **Черновик, не действующий документ.**") == {"draft"}
    assert doc_checks("a.md", "## Для юриста\n") == {"draft"}
    assert doc_checks("a.md", "Раздел ниже удалить из публикуемого текста.") == {"draft"}
    assert doc_checks("a.md", "Эти клипы не публиковать.") == {"draft"}
    assert doc_checks("a.md", "TODO: дописать") == {"draft"}
    assert doc_checks("a.md", "Срок: TBD.") == {"draft"}


def test_draft_words_that_are_fine():
    assert doc_checks("a.md", "# Выпуск\n\nТег создаёт **черновик** выпуска на GitHub.") == set()
    assert doc_checks("a.md", "# Выпуск\n\n> Сначала черновик релиза, потом публикация.") == set()
    assert doc_checks("a.md", "Я отправил черновик договора.") == set()
    assert doc_checks("a.md", "Код: `TODO` и\n```\n# TODO черновик [куда]\n```\n") == set()
    assert doc_checks("lipread/phrases_ru.txt", "Отправил черновик договора, жду ваших правок.") == set()
    assert doc_checks("mac/vendor/x/README.md", "TODO: upstream note") == set()


def test_placeholders():
    assert doc_checks("a.md", "Пишите [куда писать].") == {"placeholder"}
    assert doc_checks("a.md", "[Оператор, адрес, почта.]") == {"placeholder"}
    assert "placeholder" in doc_checks("a.md", "Срок хранения [TBD].")
    assert doc_checks("a.md", "Размер около **[3,6 МБ]**.") == {"placeholder"}


def test_brackets_that_are_not_placeholders():
    text = "\n".join([
        "См. [политику](PRIVACY.md) и [условия][terms], ![рисунок](a.png).",
        "- [ ] сделать",
        "- [x] сделано",
        "Ряд клавиш `[123] [пробел]` и [1], [a, b], [^сноска], [!NOTE].",
        "Ссылка [по ссылке].",
        "",
        "[terms]: TERMS.md",
        "[по ссылке]: https://example.com",
    ])
    assert doc_checks("a.md", text) == set()


def test_status_tags_are_not_placeholders():
    assert doc_checks("DESIGN.md", "Пометки: **[реализовано]** есть код, **[план]** кода нет. Сделано [частично].") == set()
    assert doc_checks("DESIGN.md", "Ключ в файле. [план: Keychain вместо файла]") == {"placeholder"}


def test_issue_template_titles():
    yml = 'name: Проблема\ntitle: "[Проблема] "\nbody:\n  - type: textarea\n    attributes:\n      label: Что\n'
    assert doc_checks(".github/ISSUE_TEMPLATE/problem.yml", yml) == set()
    assert doc_checks(".github/ISSUE_TEMPLATE/problem.yml", yml + "      placeholder: [куда писать]\n") == {"placeholder"}
    assert doc_checks(".github/workflows/x.yml", "# TODO\n") == set()
