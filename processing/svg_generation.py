"""SVG serialization and optional CairoSVG raster diagnostics."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape

import cv2
import numpy as np

from .conservative_vectorization import VectorizationResult
from .faithful_vectorization import FaithfulVectorizationResult
from .vectorization import CenterlineVectorizationResult


@dataclass(frozen=True)
class RasterComparison:
    """Simple pixel-domain comparison between an SVG rendering and reference."""

    mean_absolute_error: float
    root_mean_square_error: float
    similarity: float
    raster_path: Path | None
    available: bool
    message: str | None = None


VectorResult = VectorizationResult | CenterlineVectorizationResult | FaithfulVectorizationResult


def _selected(result: VectorResult) -> VectorizationResult | CenterlineVectorizationResult:
    if isinstance(result, FaithfulVectorizationResult):
        selected = result.filled if result.selected_method == "conservative" else result.centerlines
        if selected is None:
            raise ValueError("faithful result has no selected vector output")
        return selected
    return result


def generate_svg(
    result: VectorResult,
    background: str | None = "#ffffff",
    metadata: dict[str, Any] | None = None,
) -> str:
    """Serialize filled or centerline vectors into a standalone SVG string."""
    selected = _selected(result)
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{selected.width}" '
            f'height="{selected.height}" viewBox="0 0 {selected.width} {selected.height}">'
        ),
    ]
    if metadata:
        content = escape("; ".join(f"{key}={value}" for key, value in sorted(metadata.items())))
        lines.append(f"  <metadata>{content}</metadata>")
    if background is not None:
        lines.append(
            f'  <rect width="100%" height="100%" fill="{escape(background)}" data-role="background"/>'
        )
    if isinstance(selected, VectorizationResult):
        for region in selected.regions:
            lines.append(
                f'  <path id="{escape(region.region_id)}" d="{region.path_data}" '
                f'fill="{escape(region.fill)}" fill-rule="{region.fill_rule}" '
                f'data-ink="{escape(region.ink_color)}"/>'
            )
    else:
        for index, path in enumerate(selected.paths):
            lines.append(
                f'  <path id="stroke-{index}" d="{path.path_data}" fill="none" '
                f'stroke="{escape(path.stroke)}" stroke-width="{path.stroke_width:.2f}" '
                f'stroke-linecap="round" stroke-linejoin="round" '
                f'data-ink="{escape(path.ink_color)}"/>'
            )
    lines.append("</svg>")
    return "\n".join(lines)


def write_svg(
    result: VectorResult,
    path: str | Path,
    background: str | None = "#ffffff",
    metadata: dict[str, Any] | None = None,
) -> Path:
    """Write generated SVG text and return the resulting path."""
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(generate_svg(result, background, metadata), encoding="utf-8")
    return destination


def rasterize_svg(
    svg: str | bytes | Path,
    output_path: str | Path | None = None,
    output_width: int | None = None,
    output_height: int | None = None,
) -> np.ndarray | None:
    """Rasterize SVG to BGR with CairoSVG, or return ``None`` if unavailable."""
    try:
        import cairosvg
    except (ImportError, OSError):
        return None
    is_path = isinstance(svg, Path)
    if isinstance(svg, str) and not svg.lstrip().startswith("<"):
        candidate = Path(svg)
        is_path = candidate.suffix.lower() == ".svg" and candidate.exists()
    if is_path:
        png = cairosvg.svg2png(
            url=str(svg), output_width=output_width, output_height=output_height
        )
    else:
        source = svg.encode("utf-8") if isinstance(svg, str) else svg
        png = cairosvg.svg2png(
            bytestring=source, output_width=output_width, output_height=output_height
        )
    decoded = cv2.imdecode(np.frombuffer(png, dtype=np.uint8), cv2.IMREAD_COLOR)
    if decoded is None:
        return None
    if output_path is not None:
        destination = Path(output_path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(destination), decoded)
    return decoded


def compare_svg_to_raster(
    svg: str | bytes | Path,
    reference: np.ndarray,
    output_path: str | Path | None = None,
) -> RasterComparison:
    """Optionally rasterize and compare an SVG against a BGR reference."""
    height, width = reference.shape[:2]
    try:
        rendered = rasterize_svg(svg, output_path, width, height)
    except Exception as error:  # Cairo/native errors must not break processing.
        return RasterComparison(0.0, 0.0, 0.0, None, False, str(error))
    if rendered is None:
        return RasterComparison(0.0, 0.0, 0.0, None, False, "CairoSVG unavailable")
    difference = rendered.astype(np.float32) - reference[:, :, :3].astype(np.float32)
    mae = float(np.mean(np.abs(difference)))
    rmse = float(np.sqrt(np.mean(difference * difference)))
    similarity = float(np.clip(1.0 - mae / 255.0, 0.0, 1.0))
    return RasterComparison(
        mae,
        rmse,
        similarity,
        Path(output_path) if output_path is not None else None,
        True,
    )
