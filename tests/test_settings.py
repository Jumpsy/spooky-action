"""Settings are the thing users touch most, so they get the tightest tests."""
import json

import pytest

from spooky import settings


def test_defaults_are_complete():
    cfg = settings.config()
    for s in settings.SETTINGS:
        assert s.key in cfg, f"{s.key} missing from a fresh config"


def test_every_setting_explains_itself():
    for s in settings.SETTINGS:
        assert s.blurb and s.blurb[0].isupper() and s.blurb.endswith("."), s.key


def test_unknown_key_is_refused_not_swallowed(tmp_path, monkeypatch):
    monkeypatch.setenv("SPOOKY_HOME", str(tmp_path))
    with pytest.raises(KeyError):
        settings.set_values({"acccent": "yellow"})


def test_coerce_accepts_how_people_actually_type_booleans():
    for yes in ("yes", "on", "true", "True", "1"):
        assert settings.coerce(settings.by_key("glow"), yes) is True
    for no in ("no", "off", "false", "0"):
        assert settings.coerce(settings.by_key("glow"), no) is False


def test_colour_names_and_hex_both_survive_a_round_trip(tmp_path, monkeypatch):
    monkeypatch.setenv("SPOOKY_HOME", str(tmp_path))
    settings.set_values({"accent": "#ff00aa"})
    assert settings.config()["accent"] == "#ff00aa"
    settings.set_values({"accent": "yellow"})
    assert settings.config()["accent"] == "yellow"


def test_written_config_is_json_the_swift_side_can_read(tmp_path, monkeypatch):
    monkeypatch.setenv("SPOOKY_HOME", str(tmp_path))
    settings.set_values({"accent": "green", "wash": "0.1"})
    on_disk = json.loads(settings.path().read_text())
    assert on_disk["accent"] == "green"
    assert isinstance(on_disk["wash"], float)


def test_reset_really_resets(tmp_path, monkeypatch):
    monkeypatch.setenv("SPOOKY_HOME", str(tmp_path))
    settings.set_values({"accent": "red"})
    assert settings.reset()["accent"] == "yellow"


def test_by_key_suggests_the_thing_you_meant():
    with pytest.raises(KeyError) as e:
        settings.by_key("acccent")
    assert "accent" in str(e.value)
