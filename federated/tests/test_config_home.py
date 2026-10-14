"""Каталог установки после переименования: новый, прежний (~/.govorun-federated) или из переменной окружения."""
from pathlib import Path

import pytest

from client import config


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.delenv("VELIKIY_MOGUCHIY_FED_HOME", raising=False)
    monkeypatch.delenv("GOVORUN_FED_HOME", raising=False)
    return tmp_path


def test_fresh_install_uses_new_directory(home):
    assert config.home_dir() == home / ".velikiy-moguchiy-federated"


def test_legacy_directory_is_kept_while_new_one_is_absent(home):
    (home / ".govorun-federated").mkdir()
    assert config.home_dir() == home / ".govorun-federated"
    (home / ".velikiy-moguchiy-federated").mkdir()
    assert config.home_dir() == home / ".velikiy-moguchiy-federated"


def test_environment_overrides_new_then_legacy_variable(home, monkeypatch):
    monkeypatch.setenv("GOVORUN_FED_HOME", str(home / "old"))
    assert config.home_dir() == home / "old"
    monkeypatch.setenv("VELIKIY_MOGUCHIY_FED_HOME", str(home / "new"))
    assert config.home_dir() == home / "new"


def test_features_dir_follows_the_install_directory(home):
    (home / ".govorun-federated").mkdir()
    cfg = config.load_config()
    assert Path(cfg.training.features_dir) == home / ".govorun-federated" / "features"


def test_explicit_features_dir_is_kept(tmp_path):
    (tmp_path / "config.toml").write_text('[training]\nfeatures_dir = "/data/feats"\n')
    assert config.load_config(tmp_path).training.features_dir == "/data/feats"


def test_directly_built_config_has_features_under_its_home(tmp_path):
    assert Path(config.ClientConfig(home=tmp_path).training.features_dir) == tmp_path / "features"
