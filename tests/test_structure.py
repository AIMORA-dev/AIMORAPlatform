from pathlib import Path
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SymbolLibraryBoundaryTest(unittest.TestCase):
    def test_public_metadata_and_empty_profile_are_explicit(self) -> None:
        with (ROOT / "metadata" / "library.toml").open("rb") as stream:
            library = tomllib.load(stream)
        with (ROOT / "profiles" / "aimora" / "profile.toml").open("rb") as stream:
            profile = tomllib.load(stream)
        self.assertEqual(library["schema"], "aimora-symbol-library-v1")
        self.assertTrue(library["artwork_provenance_required"])
        self.assertEqual(profile["symbol_ids"], [])


if __name__ == "__main__":
    unittest.main()
