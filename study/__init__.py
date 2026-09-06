"""Visual study assistant: render board selections and call the AI service."""

from .ai import (
    StudyAIError,
    analyze_board,
    analyze_lecture,
    explain_selection,
    follow_up_question,
    generate_study_guide,
    normalize_study_action,
)
from .storage import (
    STUDY_ID_RE,
    public_board_context,
    read_study_state,
    validate_bbox,
    write_study_state,
)

__all__ = [
    "STUDY_ID_RE",
    "StudyAIError",
    "analyze_board",
    "analyze_lecture",
    "explain_selection",
    "follow_up_question",
    "generate_study_guide",
    "normalize_study_action",
    "public_board_context",
    "read_study_state",
    "validate_bbox",
    "write_study_state",
]
