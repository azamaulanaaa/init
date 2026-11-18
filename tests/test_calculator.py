"""Tests for the Python starter helpers."""

from calculator import add


def test_add_returns_the_sum() -> None:
    """Check that add returns the sum of two integers."""
    assert add(2, 3) == 5
