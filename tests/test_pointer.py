"""The coordinate formatting, which is where a second display bites."""
from spooky import pointer


def test_positive_coordinates_are_plain():
    assert pointer._at(100, 200) == "100,200"


def test_negative_coordinates_are_marked_absolute():
    # Without the "=", cliclick reads a leading minus as *relative* — the click
    # lands somewhere else and drifts further with every call.
    assert pointer._at(-1200, 500) == "=-1200,500"
    assert pointer._at(-5, -7) == "=-5,=-7"


def test_zero_is_not_treated_as_negative():
    assert pointer._at(0, 0) == "0,0"
