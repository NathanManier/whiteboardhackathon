"""Public API for the digital-whiteboard image-processing package."""

from .analysis import AnalysisResult, analyze_whiteboard, process_whiteboard
from .board_detection import BoardDetection, detect_board, order_corners
from .conservative_vectorization import (
    ConservativeOptions,
    MAX_CONTOURS,
    MAX_POINTS_PER_CONTOUR,
    MAX_VECTOR_DIMENSION,
    MAX_VECTOR_OBJECTS,
    VectorRegion,
    VectorizationResult,
    conservative_vectorize,
)
from .faithful_vectorization import FaithfulVectorizationResult, faithful_vectorize
from .ink_detection import INK_COLORS, InkDetectionResult, detect_ink
from .master_raster import MasterRaster, create_master_raster
from .perspective import PerspectiveResult, correct_perspective, transform_points
from .skeletonization import SkeletonResult, SkeletonStroke, skeletonize_mask, skeletonize_masks
from .svg_generation import (
    RasterComparison,
    compare_svg_to_raster,
    generate_svg,
    rasterize_svg,
    write_svg,
)
from .vectorization import (
    CenterlinePath,
    CenterlineVectorizationResult,
    vectorize,
    vectorize_centerlines,
)

__all__ = [
    "AnalysisResult",
    "BoardDetection",
    "CenterlinePath",
    "CenterlineVectorizationResult",
    "ConservativeOptions",
    "FaithfulVectorizationResult",
    "INK_COLORS",
    "InkDetectionResult",
    "MAX_CONTOURS",
    "MAX_POINTS_PER_CONTOUR",
    "MAX_VECTOR_DIMENSION",
    "MAX_VECTOR_OBJECTS",
    "MasterRaster",
    "PerspectiveResult",
    "RasterComparison",
    "SkeletonResult",
    "SkeletonStroke",
    "VectorRegion",
    "VectorizationResult",
    "analyze_whiteboard",
    "compare_svg_to_raster",
    "conservative_vectorize",
    "correct_perspective",
    "create_master_raster",
    "detect_board",
    "detect_ink",
    "faithful_vectorize",
    "generate_svg",
    "order_corners",
    "process_whiteboard",
    "rasterize_svg",
    "skeletonize_mask",
    "skeletonize_masks",
    "transform_points",
    "vectorize",
    "vectorize_centerlines",
    "write_svg",
]
