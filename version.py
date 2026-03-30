"""Version information for splunk-lab."""

from pathlib import Path

VERSION_FILE = Path(__file__).parent / "VERSION"


def get_version() -> str:
    """Read version from VERSION file."""
    try:
        return VERSION_FILE.read_text().strip()
    except FileNotFoundError:
        return "unknown"


__version__ = get_version()
