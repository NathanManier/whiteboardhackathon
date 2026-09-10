"""Bounded, source-preserving PDF import helpers.

PDF pages are not passed through the photographed-whiteboard CV pipeline.
Each imported page retains a one-page PDF as its canonical visual source and
gets a derived PNG/SVG proxy solely for thumbnails, export composition, and
server-side selected-region rasterization.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass
from io import BytesIO
import math
from pathlib import Path
from typing import Iterator
from xml.sax.saxutils import escape

from PIL import Image
from pypdf import PdfReader, PdfWriter
import pypdfium2 as pdfium


class PDFImportError(ValueError):
    pass


@dataclass(frozen=True)
class ImportedPDFPage:
    index: int
    width: float
    height: float
    page_pdf: bytes
    preview_png: bytes
    proxy_svg: bytes
    extracted_text: str


def _finite_dimension(value: object, *, maximum: float) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as exc:
        raise PDFImportError("The PDF contains an invalid page size.") from exc
    if not math.isfinite(result) or result <= 0 or result > maximum:
        raise PDFImportError("The PDF contains a page that is too large.")
    return result


def inspect_pdf(
    data: bytes,
    *,
    max_pages: int,
    max_page_dimension: float,
) -> tuple[PdfReader, list[tuple[float, float]]]:
    if not data.startswith(b"%PDF-"):
        raise PDFImportError("That file is not a valid PDF.")
    try:
        reader = PdfReader(BytesIO(data), strict=True)
    except Exception as exc:
        raise PDFImportError("That PDF could not be read.") from exc
    if reader.is_encrypted:
        raise PDFImportError("Password-protected PDFs are not supported.")
    page_count = len(reader.pages)
    if page_count < 1:
        raise PDFImportError("That PDF has no pages.")
    if page_count > max_pages:
        raise PDFImportError(f"Choose a PDF with no more than {max_pages} pages.")
    dimensions: list[tuple[float, float]] = []
    for page in reader.pages:
        width = _finite_dimension(page.cropbox.width, maximum=max_page_dimension)
        height = _finite_dimension(page.cropbox.height, maximum=max_page_dimension)
        dimensions.append((width, height))
    return reader, dimensions


def _one_page_pdf(reader: PdfReader, index: int) -> bytes:
    writer = PdfWriter()
    writer.add_page(reader.pages[index])
    output = BytesIO()
    writer.write(output)
    return output.getvalue()


def _page_preview(document: pdfium.PdfDocument, index: int, width: float, height: float,
                  *, max_edge: int) -> bytes:
    scale = min(max_edge / max(width, height), 4.0)
    scale = max(scale, 0.1)
    page = document[index]
    try:
        bitmap = page.render(scale=scale, rotation=0)
        image = bitmap.to_pil().convert("RGBA")
        background = Image.new("RGBA", image.size, "white")
        background.alpha_composite(image)
        output = BytesIO()
        background.convert("RGB").save(output, format="PNG", optimize=True)
        return output.getvalue()
    finally:
        page.close()


def _proxy_svg(preview_png: bytes, width: float, height: float, page_number: int) -> bytes:
    encoded = base64.b64encode(preview_png).decode("ascii")
    # The image ID is stable and is the single selectable identity for the
    # locked PDF source surface. User annotations remain separate objects.
    markup = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width:.4f}" '
        f'height="{height:.4f}" viewBox="0 0 {width:.4f} {height:.4f}">'
        '<rect width="100%" height="100%" fill="#ffffff"/>'
        f'<image id="pdf-page-1" data-source-page="{page_number}" data-ink="pdf-source" x="0" y="0" '
        f'width="{width:.4f}" height="{height:.4f}" '
        f'href="data:image/png;base64,{escape(encoded)}"/>'
        '</svg>'
    )
    return markup.encode("utf-8")


def import_pdf_pages(
    data: bytes,
    *,
    max_pages: int,
    max_page_dimension: float,
    preview_max_edge: int,
    max_extracted_text: int = 20_000,
) -> Iterator[ImportedPDFPage]:
    reader, dimensions = inspect_pdf(
        data,
        max_pages=max_pages,
        max_page_dimension=max_page_dimension,
    )
    try:
        document = pdfium.PdfDocument(data)
    except Exception as exc:
        raise PDFImportError("That PDF could not be rendered safely.") from exc
    try:
        for index, (width, height) in enumerate(dimensions):
            try:
                text = (reader.pages[index].extract_text() or "")[:max_extracted_text]
            except Exception:
                text = ""
            preview = _page_preview(
                document,
                index,
                width,
                height,
                max_edge=preview_max_edge,
            )
            yield ImportedPDFPage(
                index=index,
                width=width,
                height=height,
                page_pdf=_one_page_pdf(reader, index),
                preview_png=preview,
                proxy_svg=_proxy_svg(preview, width, height, index + 1),
                extracted_text=text,
            )
    finally:
        document.close()
