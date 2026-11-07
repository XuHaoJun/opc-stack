"""Track/style label tests.

The rules that matter: an explicit marker beats the lane default, conflicting
track labels resolve to `unknown` (never to "first one"), and a legacy ticket
with no label is classified from its assignee — that is what makes `Lab 0%`
exact for tickets that predate the change.
"""

import unittest

from opc_bridge import labels


class MarkerTest(unittest.TestCase):
    def test_lane_defaults(self):
        self.assertEqual(labels.labels_for_markers({"lane": "engineering"}), {"track:core", "style:blueprint"})
        self.assertEqual(labels.labels_for_markers({"lane": "research"}), {"track:lab", "style:exploration"})

    def test_explicit_marker_wins(self):
        self.assertEqual(
            labels.labels_for_markers({"lane": "engineering", "track": "lab", "style": "exploration"}),
            {"track:lab", "style:exploration"},
        )

    def test_marker_parsing_is_line_based_and_case_insensitive(self):
        text = "Lane: prototype\nTrack: Lab\nStyle: Blueprint\nACCEPTANCE: x"
        self.assertEqual(labels.parse_markers(text), {"lane": "prototype", "track": "lab", "style": "blueprint"})


class TrackResolutionTest(unittest.TestCase):
    def test_labels_win_over_the_agent(self):
        self.assertEqual(labels.track_of({"track:lab"}, {"role": "engineer"}), "lab")

    def test_conflicting_labels_are_unknown(self):
        self.assertEqual(labels.track_of({"track:core", "track:lab"}), "unknown")

    def test_unlabeled_legacy_ticket_falls_back_to_the_assignee(self):
        self.assertEqual(labels.track_of(set(), {"role": "engineer"}), "core")
        self.assertEqual(labels.track_of(set(), {"name": "Prototyper"}), "lab")
        self.assertEqual(labels.track_of(set(), {"name": "Scientist"}), "lab")
        self.assertEqual(labels.track_of(set(), None), "unknown")

    def test_ensure_creates_only_missing_labels(self):
        class Client:
            def __init__(self):
                self.created = []

            def labels(self):
                return [{"id": "l1", "name": "track:core"}]

            def create_label(self, name, color):
                self.created.append(name)
                return {"id": f"id-{name}"}

        client = Client()
        result = labels.ensure_labels(client)
        self.assertEqual(result["track:core"], "l1")
        self.assertNotIn("track:core", client.created)
        self.assertEqual(set(client.created), {"track:lab", "style:blueprint", "style:exploration"})


if __name__ == "__main__":
    unittest.main()
