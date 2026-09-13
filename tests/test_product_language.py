import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "product_language_audit", ROOT / "scripts" / "audit_product_language.py"
)
assert SPEC and SPEC.loader
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class ProductLanguageAuditTests(unittest.TestCase):
    def test_shipping_surfaces_use_class_terminology(self):
        findings = AUDIT.visible_runtime_findings(AUDIT.tracked_text_files())
        self.assertEqual(findings, [], "\n".join(findings))


if __name__ == "__main__":
    unittest.main()
