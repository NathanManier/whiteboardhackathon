from __future__ import annotations

import io
import json
import tempfile
import unittest
from pathlib import Path

from pypdf import PdfWriter

import app as board_app
from pdf_import import PDFImportError, import_pdf_pages, inspect_pdf


def pdf_bytes(page_count: int = 1, *, encrypted: bool = False) -> bytes:
    writer = PdfWriter()
    for index in range(page_count):
        writer.add_blank_page(width=612 + index * 10, height=792)
    if encrypted:
        writer.encrypt("secret")
    output = io.BytesIO()
    writer.write(output)
    return output.getvalue()


class PDFImportUnitTests(unittest.TestCase):
    def test_pages_preserve_pdf_and_create_stable_proxy_identity(self):
        pages = list(import_pdf_pages(
            pdf_bytes(2), max_pages=5, max_page_dimension=10_000,
            preview_max_edge=512,
        ))
        self.assertEqual(len(pages), 2)
        self.assertTrue(pages[0].page_pdf.startswith(b"%PDF-"))
        self.assertTrue(pages[0].preview_png.startswith(b"\x89PNG"))
        self.assertIn(b'id="pdf-page-1"', pages[0].proxy_svg)
        self.assertIn(b'id="pdf-page-1"', pages[1].proxy_svg)
        self.assertIn(b'data-source-page="2"', pages[1].proxy_svg)
        self.assertEqual((pages[0].width, pages[0].height), (612.0, 792.0))

    def test_invalid_encrypted_page_limit_and_page_dimension_are_rejected(self):
        with self.assertRaises(PDFImportError):
            inspect_pdf(b"not pdf", max_pages=5, max_page_dimension=10_000)
        with self.assertRaises(PDFImportError):
            inspect_pdf(pdf_bytes(encrypted=True), max_pages=5, max_page_dimension=10_000)
        with self.assertRaises(PDFImportError):
            inspect_pdf(pdf_bytes(3), max_pages=2, max_page_dimension=10_000)
        with self.assertRaises(PDFImportError):
            inspect_pdf(pdf_bytes(), max_pages=5, max_page_dimension=100)


class PDFImportRouteTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.original_boards_dir = board_app.BOARDS_DIR
        board_app.BOARDS_DIR = Path(self.temporary.name) / "boards"
        board_app.BOARDS_DIR.mkdir()
        board_app.app.config.update(TESTING=True, AUTH_TEST_BYPASS=True)
        self.client = board_app.app.test_client()

    def tearDown(self):
        board_app.BOARDS_DIR = self.original_boards_dir
        self.temporary.cleanup()

    def create_lecture(self) -> str:
        response = self.client.post("/api/folders", json={"name": "Calculus II"})
        self.assertEqual(response.status_code, 201, response.get_data(as_text=True))
        return response.get_json()["folder"]["id"]

    def upload(self, value: bytes, *, folder_id: str | None = None):
        fields = {
            "pdf": (io.BytesIO(value), "Freeform Notes.pdf", "application/pdf"),
            "source_kind": "freeform_pdf",
        }
        if folder_id:
            fields["folder_id"] = folder_id
        return self.client.post(
            "/api/import/pdf", data=fields, content_type="multipart/form-data",
            headers={"Accept": "application/json"},
        )

    def test_multi_page_pdf_creates_ordered_isolated_boards_and_workspace_items(self):
        folder_id = self.create_lecture()
        response = self.upload(pdf_bytes(3), folder_id=folder_id)
        self.assertEqual(response.status_code, 201, response.get_data(as_text=True))
        payload = response.get_json()
        self.assertEqual(payload["page_count"], 3)
        board_ids = [item["id"] for item in payload["boards"]]
        self.assertEqual(len(set(board_ids)), 3)
        library = board_app.read_library()
        self.assertEqual(board_app.folder_board_ids(library, folder_id), board_ids)
        with board_app.app.test_request_context():
            workspace = board_app.read_lecture_workspace(library, folder_id)
        self.assertEqual([item["board_id"] for item in workspace["items"]], board_ids)
        self.assertLess(workspace["items"][0]["canvas_x"], workspace["items"][1]["canvas_x"])
        for index, board_id in enumerate(board_ids, start=1):
            directory = board_app.BOARDS_DIR / board_id
            metadata = json.loads((directory / "board.json").read_text())
            self.assertEqual(metadata["source_kind"], "freeform_pdf")
            self.assertEqual(metadata["source"]["page_number"], index)
            self.assertEqual(metadata["pipeline"]["kind"], "pdf_source")
            self.assertTrue((directory / "source.pdf").is_file())
            self.assertTrue((directory / "board.svg").is_file())
            editor = self.client.get(f"/api/boards/{board_id}/editor").get_json()["editor"]
            self.assertEqual(editor["objects"], [])

    def test_pdf_asset_and_source_metadata_are_exposed_but_original_import_is_not(self):
        response = self.upload(pdf_bytes())
        board = response.get_json()["boards"][0]
        board_id = board["id"]
        metadata = self.client.get(
            f"/board/{board_id}", headers={"Accept": "application/json"}
        ).get_json()
        self.assertEqual(metadata["source_kind"], "freeform_pdf")
        self.assertIn(board_id, metadata["pdf_url"])
        self.assertTrue(metadata["pdf_url"].endswith("/source.pdf"))
        asset = self.client.get(metadata["pdf_url"])
        self.assertEqual(asset.status_code, 200)
        self.assertEqual(asset.mimetype, "application/pdf")
        self.assertEqual(self.client.get(f"/boards/.imports/{response.get_json()['import_id']}/source.pdf").status_code, 404)

    def test_invalid_and_encrypted_pdf_fail_without_library_mutation(self):
        for content in (b"not a PDF", pdf_bytes(encrypted=True)):
            with self.subTest(prefix=content[:10]):
                response = self.upload(content)
                self.assertEqual(response.status_code, 400, response.get_data(as_text=True))
        self.assertEqual(board_app.read_library()["boards"], {})


if __name__ == "__main__":
    unittest.main()
