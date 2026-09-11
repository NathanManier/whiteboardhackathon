from __future__ import annotations

import unittest

from study.graph_export import static_graph_primitives


class StaticGraphExportTests(unittest.TestCase):
    @staticmethod
    def graph(expressions: list[dict]) -> dict:
        return {
            "viewport": {"x_min": -10, "x_max": 10, "y_min": -10, "y_max": 10},
            "expressions": expressions,
        }

    def primitives(self, expressions: list[dict]):
        return static_graph_primitives(
            self.graph(expressions),
            plot_x=20,
            plot_y=30,
            plot_width=400,
            plot_height=300,
        )

    def test_p0_expression_types_emit_finite_provider_independent_geometry(self):
        expressions = [
            {"id": "parabola", "latex": "y=x^2-4", "type": "explicitFunction"},
            {"id": "horizontal", "latex": "y=3", "type": "horizontalLine"},
            {"id": "vertical", "latex": "x=-2", "type": "verticalLine"},
            {"id": "point", "latex": "(2,3)", "type": "point"},
            {"id": "circle", "latex": "x^2+y^2=9", "type": "implicitEquation"},
        ]
        primitives = self.primitives(expressions)
        self.assertEqual(
            [item.attributes["data-expression-id"] for item in primitives],
            ["parabola", "horizontal", "vertical", "point", "circle"],
        )
        self.assertEqual([item.tag for item in primitives], ["path", "path", "path", "circle", "path"])
        self.assertGreater(primitives[0].attributes["d"].count("L "), 100)
        self.assertEqual(primitives[1].attributes["d"].count("L "), 1)
        self.assertEqual(primitives[2].attributes["d"].count("L "), 1)
        self.assertGreater(primitives[4].attributes["d"].count("L "), 100)
        serialized = " ".join(
            " ".join(item.attributes.values()) for item in primitives
        ).lower()
        self.assertNotIn("nan", serialized)
        self.assertNotIn("inf", serialized)

    def test_fraction_discontinuity_is_split_without_connecting_across_zero(self):
        primitive = self.primitives([{
            "id": "reciprocal",
            "latex": r"y=\frac{1}{x}",
            "type": "explicitFunction",
        }])[0]
        self.assertGreaterEqual(primitive.attributes["d"].count("M "), 2)
        self.assertNotIn("nan", primitive.attributes["d"].lower())
        self.assertNotIn("inf", primitive.attributes["d"].lower())

    def test_steep_continuous_line_is_not_mistaken_for_an_asymptote(self):
        primitive = self.primitives([{
            "id": "steep",
            "latex": "y=1000x",
            "type": "explicitFunction",
        }])[0]
        self.assertEqual(primitive.attributes["d"].count("M "), 1)
        self.assertGreaterEqual(primitive.attributes["d"].count("L "), 1)

    def test_unsupported_restricted_hidden_and_code_like_expressions_fail_closed(self):
        primitives = self.primitives([
            {"id": "future", "latex": "y=x", "type": "futureSpline"},
            {
                "id": "restricted", "latex": "y=x^2", "type": "explicitFunction",
                "restrictions": ["x>0"],
            },
            {"id": "hidden", "latex": "y=x", "type": "explicitFunction", "visible": False},
            {
                "id": "code-like", "latex": "y=__import__(os)",
                "type": "explicitFunction",
            },
            {
                "id": "unsafe-command", "latex": r"y=\input{secret}",
                "type": "explicitFunction",
            },
        ])
        self.assertEqual(primitives, [])

    def test_style_is_bounded_and_applied_to_export_geometry(self):
        primitive = self.primitives([{
            "id": "styled",
            "latex": "y=x",
            "type": "explicitFunction",
            "display_style": {
                "color": "#C74440",
                "line_width": 3,
                "line_style": "dashed",
                "opacity": 0.65,
            },
        }])[0]
        self.assertEqual(primitive.attributes["stroke"], "#c74440")
        self.assertEqual(primitive.attributes["stroke-width"], "3.000")
        self.assertEqual(primitive.attributes["stroke-opacity"], "0.6500")
        self.assertEqual(primitive.attributes["stroke-dasharray"], "8 6")


if __name__ == "__main__":
    unittest.main()
