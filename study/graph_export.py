from __future__ import annotations

import math
import re
from dataclasses import dataclass
from typing import Any


MAX_STATIC_GRAPH_SAMPLES = 385
MAX_STATIC_GRAPH_AST_NODES = 160
MAX_STATIC_GRAPH_PARSE_DEPTH = 24

_NUMBER_RE = re.compile(r"(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?")
_IDENTIFIER_RE = re.compile(r"[A-Za-z]+")
_SAFE_COLOR_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")
_SAFE_EXPRESSION_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
_FUNCTIONS = {"sin", "cos", "tan", "sqrt", "abs", "exp", "ln", "log"}
_COMMANDS = {
    "sin": "sin",
    "cos": "cos",
    "tan": "tan",
    "sqrt": "sqrt",
    "abs": "abs",
    "ln": "ln",
    "log": "log",
    "exp": "exp",
    "pi": "pi",
    "cdot": "*",
    "times": "*",
}


class StaticGraphParseError(ValueError):
    pass


@dataclass(frozen=True)
class StaticGraphPrimitive:
    tag: str
    attributes: dict[str, str]


@dataclass(frozen=True)
class _Token:
    kind: str
    value: str


_Node = tuple[Any, ...]


def _braced_group(value: str, start: int) -> tuple[str, int]:
    if start >= len(value) or value[start] != "{":
        raise StaticGraphParseError("Expected a braced group.")
    depth = 1
    index = start + 1
    while index < len(value):
        character = value[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return value[start + 1:index], index + 1
        index += 1
    raise StaticGraphParseError("Unbalanced LaTeX group.")


def _plain_math(value: str, *, depth: int = 0) -> str:
    if depth > 10:
        raise StaticGraphParseError("LaTeX is nested too deeply.")
    raw = value.strip()
    if len(raw) >= 2 and raw.startswith("$") and raw.endswith("$"):
        raw = raw[1:-1]
    if raw.startswith(r"\(") and raw.endswith(r"\)"):
        raw = raw[2:-2]
    raw = raw.replace("−", "-").replace("×", "*").replace("²", "^2").replace("³", "^3")
    output: list[str] = []
    index = 0
    while index < len(raw):
        character = raw[index]
        if character != "\\":
            if character == "{":
                output.append("(")
            elif character == "}":
                output.append(")")
            else:
                output.append(character)
            index += 1
            continue
        match = re.match(r"\\([A-Za-z]+)", raw[index:])
        if match is None:
            raise StaticGraphParseError("Unsupported LaTeX escape.")
        command = match.group(1)
        index += len(match.group(0))
        if command in {"left", "right"}:
            continue
        if command == "frac":
            numerator, index = _braced_group(raw, index)
            denominator, index = _braced_group(raw, index)
            output.append(
                f"(({_plain_math(numerator, depth=depth + 1)})/"
                f"({_plain_math(denominator, depth=depth + 1)}))"
            )
            continue
        if command == "operatorname":
            name, index = _braced_group(raw, index)
            normalized_name = name.strip().lower()
            if normalized_name not in _FUNCTIONS:
                raise StaticGraphParseError("Unsupported operator.")
            output.append(normalized_name)
            continue
        mapped = _COMMANDS.get(command)
        if mapped is None:
            raise StaticGraphParseError("Unsupported LaTeX command.")
        output.append(mapped)
    return "".join(output)


def _tokenize(value: str) -> list[_Token]:
    tokens: list[_Token] = []
    index = 0
    while index < len(value):
        character = value[index]
        if character.isspace():
            index += 1
            continue
        number = _NUMBER_RE.match(value, index)
        if number is not None:
            tokens.append(_Token("number", number.group(0)))
            index = number.end()
            continue
        identifier = _IDENTIFIER_RE.match(value, index)
        if identifier is not None:
            tokens.append(_Token("identifier", identifier.group(0).lower()))
            index = identifier.end()
            continue
        if character in "+-*/^(),=":
            tokens.append(_Token(character, character))
            index += 1
            continue
        raise StaticGraphParseError("Unsupported expression character.")
    tokens.append(_Token("end", ""))
    return tokens


class _Parser:
    def __init__(self, value: str):
        self.tokens = _tokenize(value)
        self.index = 0
        self.node_count = 0

    @property
    def current(self) -> _Token:
        return self.tokens[self.index]

    def _node(self, *parts: Any) -> _Node:
        self.node_count += 1
        if self.node_count > MAX_STATIC_GRAPH_AST_NODES:
            raise StaticGraphParseError("Expression is too complex.")
        return tuple(parts)

    def _take(self, kind: str) -> _Token:
        if self.current.kind != kind:
            raise StaticGraphParseError(f"Expected {kind}.")
        result = self.current
        self.index += 1
        return result

    def parse(self) -> _Node:
        result = self._additive(0)
        if self.current.kind != "end":
            raise StaticGraphParseError("Unexpected expression token.")
        return result

    def _additive(self, depth: int) -> _Node:
        left = self._multiplicative(depth + 1)
        while self.current.kind in {"+", "-"}:
            operator = self.current.kind
            self.index += 1
            left = self._node("binary", operator, left, self._multiplicative(depth + 1))
        return left

    def _multiplicative(self, depth: int) -> _Node:
        left = self._unary(depth + 1)
        while True:
            if self.current.kind in {"*", "/"}:
                operator = self.current.kind
                self.index += 1
                right = self._unary(depth + 1)
            elif self.current.kind in {"number", "identifier", "("}:
                operator = "*"
                right = self._unary(depth + 1)
            else:
                break
            left = self._node("binary", operator, left, right)
        return left

    def _unary(self, depth: int) -> _Node:
        self._check_depth(depth)
        if self.current.kind in {"+", "-"}:
            operator = self.current.kind
            self.index += 1
            return self._node("unary", operator, self._unary(depth + 1))
        return self._power(depth + 1)

    def _power(self, depth: int) -> _Node:
        self._check_depth(depth)
        value = self._primary(depth + 1)
        if self.current.kind == "^":
            self.index += 1
            return self._node("binary", "^", value, self._unary(depth + 1))
        return value

    def _primary(self, depth: int) -> _Node:
        self._check_depth(depth)
        if self.current.kind == "number":
            return self._node("number", float(self._take("number").value))
        if self.current.kind == "identifier":
            name = self._take("identifier").value
            if name in _FUNCTIONS:
                self._take("(")
                argument = self._additive(depth + 1)
                self._take(")")
                return self._node("function", name, argument)
            if name not in {"x", "y", "pi", "e"}:
                raise StaticGraphParseError("Unknown identifier.")
            return self._node("identifier", name)
        if self.current.kind == "(":
            self.index += 1
            result = self._additive(depth + 1)
            self._take(")")
            return result
        raise StaticGraphParseError("Expected a number, variable, or group.")

    @staticmethod
    def _check_depth(depth: int) -> None:
        if depth > MAX_STATIC_GRAPH_PARSE_DEPTH:
            raise StaticGraphParseError("Expression is nested too deeply.")


def _parse(value: str) -> _Node:
    return _Parser(value).parse()


def _variables(node: _Node) -> set[str]:
    kind = node[0]
    if kind == "identifier":
        return {node[1]} if node[1] in {"x", "y"} else set()
    if kind in {"number"}:
        return set()
    if kind in {"unary", "function"}:
        return _variables(node[-1])
    if kind == "binary":
        return _variables(node[2]) | _variables(node[3])
    return set()


def _evaluate(
    node: _Node,
    *,
    x: float = 0,
    y: float = 0,
    angle_mode: str = "radians",
    depth: int = 0,
) -> float:
    if depth > MAX_STATIC_GRAPH_PARSE_DEPTH:
        raise ArithmeticError("Expression is nested too deeply.")
    kind = node[0]
    if kind == "number":
        result = float(node[1])
    elif kind == "identifier":
        result = {"x": x, "y": y, "pi": math.pi, "e": math.e}[node[1]]
    elif kind == "unary":
        operand = _evaluate(
            node[2], x=x, y=y, angle_mode=angle_mode, depth=depth + 1
        )
        result = operand if node[1] == "+" else -operand
    elif kind == "binary":
        left = _evaluate(
            node[2], x=x, y=y, angle_mode=angle_mode, depth=depth + 1
        )
        right = _evaluate(
            node[3], x=x, y=y, angle_mode=angle_mode, depth=depth + 1
        )
        if node[1] == "+":
            result = left + right
        elif node[1] == "-":
            result = left - right
        elif node[1] == "*":
            result = left * right
        elif node[1] == "/":
            if abs(right) < 1e-12:
                raise ArithmeticError("Division by zero.")
            result = left / right
        else:
            if abs(right) > 24 or (left < 0 and not float(right).is_integer()):
                raise ArithmeticError("Unsafe exponent.")
            result = math.pow(left, right)
    elif kind == "function":
        argument = _evaluate(
            node[2], x=x, y=y, angle_mode=angle_mode, depth=depth + 1
        )
        trig_argument = math.radians(argument) if angle_mode == "degrees" else argument
        if node[1] == "sin":
            result = math.sin(trig_argument)
        elif node[1] == "cos":
            result = math.cos(trig_argument)
        elif node[1] == "tan":
            result = math.tan(trig_argument)
        elif node[1] == "sqrt":
            if argument < 0:
                raise ArithmeticError("Square root domain error.")
            result = math.sqrt(argument)
        elif node[1] == "abs":
            result = abs(argument)
        elif node[1] == "exp":
            if argument > 30:
                raise ArithmeticError("Exponential overflow.")
            result = math.exp(argument)
        elif node[1] in {"ln", "log"}:
            if argument <= 0:
                raise ArithmeticError("Logarithm domain error.")
            result = math.log(argument) if node[1] == "ln" else math.log10(argument)
        else:
            raise ArithmeticError("Unsupported function.")
    else:
        raise ArithmeticError("Unsupported expression.")
    if not math.isfinite(result) or abs(result) > 1e12:
        raise ArithmeticError("Non-finite result.")
    return result


def _split_relation(value: str) -> tuple[str, str] | None:
    depth = 0
    split_at = None
    for index, character in enumerate(value):
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
        elif character == "=" and depth == 0:
            if split_at is not None:
                raise StaticGraphParseError("Multiple relations are unsupported.")
            split_at = index
    if depth != 0:
        raise StaticGraphParseError("Unbalanced expression group.")
    if split_at is None:
        return None
    return value[:split_at], value[split_at + 1:]


def _constant(node: _Node, *, angle_mode: str = "radians") -> float:
    if _variables(node):
        raise StaticGraphParseError("Expected a constant.")
    try:
        return _evaluate(node, angle_mode=angle_mode)
    except (ArithmeticError, OverflowError, ValueError) as exc:
        raise StaticGraphParseError("Invalid constant.") from exc


def _explicit_node(value: str) -> _Node:
    relation = _split_relation(value)
    if relation is None:
        node = _parse(value)
    else:
        left, right = relation
        compact_left = left.replace(" ", "")
        compact_right = right.replace(" ", "")
        if compact_left in {"y", "f(x)", "g(x)"}:
            node = _parse(right)
        elif compact_right == "y":
            node = _parse(left)
        else:
            raise StaticGraphParseError("Not an explicit function.")
    if _variables(node) - {"x"}:
        raise StaticGraphParseError("Explicit function may only use x.")
    return node


def _line_value(value: str, variable: str, *, angle_mode: str = "radians") -> float:
    relation = _split_relation(value)
    if relation is None:
        return _constant(_parse(value), angle_mode=angle_mode)
    left, right = relation
    if left.replace(" ", "") == variable:
        return _constant(_parse(right), angle_mode=angle_mode)
    if right.replace(" ", "") == variable:
        return _constant(_parse(left), angle_mode=angle_mode)
    raise StaticGraphParseError("Not a supported line.")


def _point_value(value: str, *, angle_mode: str = "radians") -> tuple[float, float]:
    raw = value.strip()
    if raw.startswith("(") and raw.endswith(")"):
        raw = raw[1:-1]
    depth = 0
    split_at = None
    for index, character in enumerate(raw):
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
        elif character == "," and depth == 0:
            if split_at is not None:
                raise StaticGraphParseError("Invalid point.")
            split_at = index
    if split_at is None or depth != 0:
        raise StaticGraphParseError("Invalid point.")
    return (
        _constant(_parse(raw[:split_at]), angle_mode=angle_mode),
        _constant(_parse(raw[split_at + 1:]), angle_mode=angle_mode),
    )


def _squared_variable(node: _Node, variable: str) -> bool:
    return (
        node[0] == "binary"
        and node[1] == "^"
        and node[2] == ("identifier", variable)
        and node[3][0] == "number"
        and node[3][1] == 2
    )


def _origin_circle_radius(value: str, *, angle_mode: str = "radians") -> float:
    relation = _split_relation(value)
    if relation is None:
        raise StaticGraphParseError("Not a circle relation.")
    left = _parse(relation[0])
    right = _parse(relation[1])

    def is_circle(node: _Node) -> bool:
        return (
            node[0] == "binary"
            and node[1] == "+"
            and (
                (_squared_variable(node[2], "x") and _squared_variable(node[3], "y"))
                or (_squared_variable(node[2], "y") and _squared_variable(node[3], "x"))
            )
        )

    if is_circle(left):
        radius_squared = _constant(right, angle_mode=angle_mode)
    elif is_circle(right):
        radius_squared = _constant(left, angle_mode=angle_mode)
    else:
        raise StaticGraphParseError("Not a supported origin circle.")
    if not 0 < radius_squared <= 1e12:
        raise StaticGraphParseError("Invalid circle radius.")
    return math.sqrt(radius_squared)


def _viewport(item: dict[str, Any]) -> tuple[float, float, float, float]:
    value = item.get("viewport") if isinstance(item.get("viewport"), dict) else {}
    try:
        x_min = float(value.get("x_min", -10))
        x_max = float(value.get("x_max", 10))
        y_min = float(value.get("y_min", -10))
        y_max = float(value.get("y_max", 10))
    except (TypeError, ValueError) as exc:
        raise StaticGraphParseError("Invalid viewport.") from exc
    if not all(math.isfinite(number) for number in (x_min, x_max, y_min, y_max)):
        raise StaticGraphParseError("Invalid viewport.")
    if x_min >= x_max or y_min >= y_max:
        raise StaticGraphParseError("Invalid viewport.")
    return x_min, x_max, y_min, y_max


def _style(expression: dict[str, Any]) -> dict[str, str]:
    source = expression.get("display_style") if isinstance(expression.get("display_style"), dict) else {}
    color = str(source.get("color") or "#2d70b3")
    if _SAFE_COLOR_RE.fullmatch(color) is None:
        color = "#2d70b3"
    try:
        width = min(8.0, max(0.5, float(source.get("line_width", 2.5))))
    except (TypeError, ValueError):
        width = 2.5
    if not math.isfinite(width):
        width = 2.5
    try:
        opacity = min(1.0, max(0.0, float(source.get("opacity", 1))))
    except (TypeError, ValueError):
        opacity = 1.0
    if not math.isfinite(opacity):
        opacity = 1.0
    result = {
        "fill": "none",
        "stroke": color.lower(),
        "stroke-width": f"{width:.3f}",
        "stroke-opacity": f"{opacity:.4f}",
        "stroke-linecap": "round",
        "stroke-linejoin": "round",
    }
    line_style = str(source.get("line_style") or "solid").lower()
    if line_style in {"dashed", "dash"}:
        result["stroke-dasharray"] = "8 6"
    elif line_style in {"dotted", "dot"}:
        result["stroke-dasharray"] = "2 5"
    return result


def _screen_point(
    x_value: float,
    y_value: float,
    *,
    plot: tuple[float, float, float, float],
    viewport: tuple[float, float, float, float],
) -> tuple[float, float]:
    plot_x, plot_y, plot_width, plot_height = plot
    x_min, x_max, y_min, y_max = viewport
    return (
        plot_x + (x_value - x_min) / (x_max - x_min) * plot_width,
        plot_y + (y_max - y_value) / (y_max - y_min) * plot_height,
    )


def _format_path(segments: list[list[tuple[float, float]]]) -> str:
    parts: list[str] = []
    for segment in segments:
        if not segment:
            continue
        first, *rest = segment
        parts.append(f"M {first[0]:.3f} {first[1]:.3f}")
        parts.extend(f"L {point[0]:.3f} {point[1]:.3f}" for point in rest)
    return " ".join(parts)


def _explicit_path(
    node: _Node,
    *,
    plot: tuple[float, float, float, float],
    viewport: tuple[float, float, float, float],
    angle_mode: str,
) -> str:
    x_min, x_max, y_min, y_max = viewport
    y_span = y_max - y_min
    sample_count = min(MAX_STATIC_GRAPH_SAMPLES, max(129, int(plot[2] * 0.75)))
    if sample_count % 2 == 0:
        sample_count += 1
    sample_count = min(sample_count, MAX_STATIC_GRAPH_SAMPLES)
    samples: list[tuple[float, float] | None] = []
    for index in range(sample_count):
        x_value = x_min + (x_max - x_min) * index / (sample_count - 1)
        try:
            y_value = _evaluate(node, x=x_value, angle_mode=angle_mode)
        except (ArithmeticError, OverflowError, ValueError):
            y_value = math.nan
        if (
            not math.isfinite(y_value)
            or y_value < y_min - y_span * 4
            or y_value > y_max + y_span * 4
        ):
            samples.append(None)
        else:
            samples.append((x_value, y_value))

    segments: list[list[tuple[float, float]]] = []
    current: list[tuple[float, float]] = []
    for left, right in zip(samples, samples[1:]):
        if left is None or right is None:
            if len(current) > 1:
                segments.append(current)
            current = []
            continue
        midpoint_x = (left[0] + right[0]) * 0.5
        try:
            midpoint_y = _evaluate(node, x=midpoint_x, angle_mode=angle_mode)
        except (ArithmeticError, OverflowError, ValueError):
            midpoint_y = math.nan
        midpoint_valid = (
            math.isfinite(midpoint_y)
            and y_min - y_span * 4 <= midpoint_y <= y_max + y_span * 4
        )
        endpoint_jump = abs(right[1] - left[1])
        midpoint_curve = (
            abs(midpoint_y - (left[1] + right[1]) * 0.5)
            if midpoint_valid
            else math.inf
        )
        discontinuity = (
            not midpoint_valid
            or (
                endpoint_jump > y_span * 1.5
                and midpoint_curve > y_span * 0.25
            )
        )
        if discontinuity:
            if len(current) > 1:
                segments.append(current)
            current = []
            continue
        left_screen = _screen_point(*left, plot=plot, viewport=viewport)
        right_screen = _screen_point(*right, plot=plot, viewport=viewport)
        if not current:
            current.append(left_screen)
        elif current[-1] != left_screen:
            if len(current) > 1:
                segments.append(current)
            current = [left_screen]
        current.append(right_screen)
    if len(current) > 1:
        segments.append(current)
    return _format_path(segments)


def static_graph_primitives(
    item: dict[str, Any],
    *,
    plot_x: float,
    plot_y: float,
    plot_width: float,
    plot_height: float,
    max_expressions: int | None = None,
) -> list[StaticGraphPrimitive]:
    """Return bounded SVG geometry for the deliberately small P0 expression subset.

    This parser never executes input. Unsupported expressions are omitted from
    the provider-independent export and remain available as the adjacent label.
    """
    if not all(
        math.isfinite(value) and value > 0
        for value in (plot_width, plot_height)
    ) or not all(math.isfinite(value) for value in (plot_x, plot_y)):
        return []
    try:
        viewport = _viewport(item)
    except StaticGraphParseError:
        return []
    plot = (plot_x, plot_y, plot_width, plot_height)
    settings = item.get("settings") if isinstance(item.get("settings"), dict) else {}
    angle_mode = str(settings.get("angle_mode") or "radians")
    if angle_mode not in {"radians", "degrees"}:
        angle_mode = "radians"
    primitives: list[StaticGraphPrimitive] = []
    considered = 0
    for expression in item.get("expressions") or []:
        if not isinstance(expression, dict) or not expression.get("visible", True):
            continue
        if max_expressions is not None and considered >= max(0, max_expressions):
            break
        considered += 1
        restrictions = expression.get("restrictions", [])
        if restrictions:
            # Exporting an unrestricted approximation would misrepresent the
            # canonical expression. Leave its readable label as the fallback.
            continue
        expression_id = str(expression.get("id") or "")
        if _SAFE_EXPRESSION_ID_RE.fullmatch(expression_id) is None:
            continue
        expression_type = str(expression.get("type") or "unknown")
        raw_latex = expression.get("latex")
        if not isinstance(raw_latex, str) or len(raw_latex) > 1_000:
            continue
        try:
            latex = _plain_math(raw_latex)
            style = _style(expression)
            if expression_type == "explicitFunction":
                path_data = _explicit_path(
                    _explicit_node(latex),
                    plot=plot,
                    viewport=viewport,
                    angle_mode=angle_mode,
                )
                if not path_data:
                    continue
                attributes = {"d": path_data, **style}
                primitive = StaticGraphPrimitive("path", attributes)
            elif expression_type == "horizontalLine":
                y_value = _line_value(latex, "y", angle_mode=angle_mode)
                start = _screen_point(viewport[0], y_value, plot=plot, viewport=viewport)
                end = _screen_point(viewport[1], y_value, plot=plot, viewport=viewport)
                primitive = StaticGraphPrimitive(
                    "path", {"d": _format_path([[start, end]]), **style}
                )
            elif expression_type == "verticalLine":
                x_value = _line_value(latex, "x", angle_mode=angle_mode)
                start = _screen_point(x_value, viewport[2], plot=plot, viewport=viewport)
                end = _screen_point(x_value, viewport[3], plot=plot, viewport=viewport)
                primitive = StaticGraphPrimitive(
                    "path", {"d": _format_path([[start, end]]), **style}
                )
            elif expression_type == "point":
                point = _point_value(latex, angle_mode=angle_mode)
                screen = _screen_point(*point, plot=plot, viewport=viewport)
                attributes = {
                    "cx": f"{screen[0]:.3f}",
                    "cy": f"{screen[1]:.3f}",
                    "r": f"{max(2.5, float(style['stroke-width']) * 1.5):.3f}",
                    "fill": style["stroke"],
                    "fill-opacity": style["stroke-opacity"],
                }
                primitive = StaticGraphPrimitive("circle", attributes)
            elif expression_type == "implicitEquation":
                radius = _origin_circle_radius(latex, angle_mode=angle_mode)
                points = [
                    _screen_point(
                        math.cos(index * math.tau / 128) * radius,
                        math.sin(index * math.tau / 128) * radius,
                        plot=plot,
                        viewport=viewport,
                    )
                    for index in range(129)
                ]
                primitive = StaticGraphPrimitive(
                    "path", {"d": _format_path([points]), **style}
                )
            else:
                continue
        except (StaticGraphParseError, ArithmeticError, OverflowError, ValueError):
            continue
        primitives.append(StaticGraphPrimitive(
            primitive.tag,
            {
                **primitive.attributes,
                "data-expression-id": expression_id,
                "data-expression-type": expression_type,
                "data-static-plot": "true",
            },
        ))
    return primitives
