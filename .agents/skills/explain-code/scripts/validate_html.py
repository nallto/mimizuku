#!/usr/bin/env python3
"""explain-codeが生成したstandalone HTMLの構造、安全性、図の予算を検証する。"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path

ALLOWED_DIAGRAM_TYPES = {
    "architecture",
    "sequence",
    "flowchart",
    "data-flow",
    "state",
    "call-tree",
    "swimlane",
    "change-map",
}
FORBIDDEN_TAGS = {"script", "object", "form", "iframe", "base", "audio", "video"}
EXPECTED_CSP = {
    "default-src": ("'none'",),
    "style-src": ("'unsafe-inline'",),
    "img-src": ("data:",),
    "base-uri": ("'none'",),
    "form-action": ("'none'",),
    "object-src": ("'none'",),
}
URI_SCHEME_RE = re.compile(r"^[a-z][a-z0-9+.-]*:", re.IGNORECASE)
REMOTE_CSS_RE = re.compile(r"@import|url\(\s*(['\"]?)(?!#|data:)", re.IGNORECASE)
PATH_TOKEN_RE = re.compile(r"[A-Za-z]|[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?")
CSS_RULE_RE = re.compile(r"([^{}]+)\{([^{}]*)\}", re.DOTALL)
EXPECTED_PALETTE = {
    "paper": "#f1f4f6",
    "surface": "#fbfdff",
    "surface-muted": "#e5ebef",
    "ink": "#202b38",
    "muted": "#526273",
    "soft": "#738395",
    "rule": "#c5d0d8",
    "accent": "#b84e68",
    "accent-soft": "#f6e2e8",
    "runtime": "#23705f",
    "runtime-soft": "#ddf0ea",
    "inferred": "#84651c",
    "inferred-soft": "#f3ecd9",
    "link": "#315f9b",
}
CHANGE_SECTION_TITLES = {
    "change-files": "変更ファイル",
    "diff-overview": "差分概要",
    "diff-details": "重要な差分",
    "verification-results": "検証結果",
}
IMPORTANT_CONTRACTS = {
    ".evidence-list": {"display": "grid", "grid-template-columns": "1fr"},
    ".evidence-row": {
        "width": "100%",
        "padding": "20px",
        "background": "var(--surface)",
        "border": "1px solid var(--rule)",
        "border-radius": "6px",
    },
    ".change-section": {
        "display": "grid",
        "grid-template-columns": "1fr",
        "width": "100%",
        "padding": "20px",
        "background": "var(--surface)",
        "border": "1px solid var(--rule)",
        "border-radius": "6px",
    },
}
REQUIRED_CSS_PATTERNS = {
    "light固定": re.compile(r"color-scheme\s*:\s*light\b"),
    "system sans token": re.compile(r"--font-sans\s*:[^;}]*sans-serif", re.DOTALL),
    "diagram横scroll": re.compile(r"\.diagram-scroll\s*\{[^}]*overflow-x\s*:\s*auto", re.DOTALL),
    "SVG最小幅": re.compile(r"\.explain-diagram\s*\{[^}]*min-width\s*:", re.DOTALL),
    "長文折返し": re.compile(r"overflow-wrap\s*:\s*anywhere"),
    "見出し領域の本文幅": re.compile(r"\.page-header\s*\{[^}]*max-width\s*:\s*1180px", re.DOTALL),
    "見出しのphrase折返し": re.compile(r"h1\s*\{[^}]*display\s*:\s*flex[^}]*flex-wrap\s*:\s*wrap", re.DOTALL),
    "見出しの通常折返し": re.compile(r"h1\s*\{[^}]*text-wrap\s*:\s*wrap", re.DOTALL),
    "見出しの日本語改行": re.compile(r"h1\s*\{[^}]*line-break\s*:\s*strict", re.DOTALL),
    "見出しのsans指定": re.compile(r"h1\s*\{[^}]*font-family\s*:\s*var\(--font-sans\)", re.DOTALL),
    "見出しの最大44px": re.compile(r"h1\s*\{[^}]*font-size\s*:\s*clamp\([^)]*44px\)", re.DOTALL),
    "見出しphraseの分割防止": re.compile(r"\.title-phrase\s*\{[^}]*white-space\s*:\s*nowrap", re.DOTALL),
    "ledeの通常折返し": re.compile(r"\.lede\s*\{[^}]*text-wrap\s*:\s*wrap", re.DOTALL),
    "ledeの全幅": re.compile(r"\.lede\s*\{[^}]*width\s*:\s*100%[^}]*max-width\s*:\s*none", re.DOTALL),
}
FORBIDDEN_CSS_PATTERNS = {
    "CSS comment": re.compile(r"/\*|\*/"),
    "CSS escape": re.compile(r"\\"),
    "OS theme分岐": re.compile(r"prefers-color-scheme", re.IGNORECASE),
    "shadow": re.compile(r"box-shadow\s*:", re.IGNORECASE),
    "gradient": re.compile(r"(?:linear|radial|conic)-gradient\s*\(", re.IGNORECASE),
    "無効なmin式": re.compile(r"min\(\s*100%\s*-", re.IGNORECASE),
    "強制的な全字折返し": re.compile(r"word-break\s*:\s*break-all", re.IGNORECASE),
    "見出しの強制折返し": re.compile(r"h1\s*\{[^}]*overflow-wrap\s*:\s*anywhere", re.IGNORECASE | re.DOTALL),
    "serif書体": re.compile(r"(?<!sans-)serif\b|Mincho", re.IGNORECASE),
    "不自然な均等折返し": re.compile(r"text-wrap\s*:\s*balance", re.IGNORECASE),
    "見出しの不安定なpretty折返し": re.compile(r"h1\s*\{[^}]*text-wrap\s*:\s*pretty", re.IGNORECASE | re.DOTALL),
    "ledeの不安定なpretty折返し": re.compile(r"\.lede\s*\{[^}]*text-wrap\s*:\s*pretty", re.IGNORECASE | re.DOTALL),
}
TYPE_NODE_LIMITS = {"sequence": 6, "state": 8}
ROLE_LIMITS = {
    "architecture": {"diagram-zone": 3},
    "sequence": {"sequence-lifeline": 6, "sequence-fragment": 1},
    "flowchart": {"flow-process": 7, "flow-decision": 3, "flow-terminal": 3},
    "data-flow": {"data-store": 3, "data-fanout": 3},
    "state": {"state-self-loop": 2},
    "swimlane": {"swimlane": 5, "swim-step": 10, "swim-handoff": 8},
    "change-map": {"is-changed": 5, "is-context": 4},
}
NODE_ROLES = {
    "flowchart": {"flow-process", "flow-decision", "flow-terminal"},
    "data-flow": {"data-source", "data-transform", "data-store", "data-sink", "data-fanout"},
}
COUNTED_ROLES = set().union(*ROLE_LIMITS.values()) | {"state-start", "state-end"}


@dataclass
class DiagramAudit:
    diagram_type: str | None
    aria_ids: list[str]
    has_view_box: bool
    nodes: int = 0
    edges: int = 0
    focal: int = 0
    focal_nodes: int = 0
    direct_children: list[str] = field(default_factory=list)
    title_ids: list[str] = field(default_factory=list)
    desc_ids: list[str] = field(default_factory=list)
    roles: Counter[str] = field(default_factory=Counter)
    seen_node: bool = False
    edge_after_node: bool = False
    fragment_depth: int = 0
    max_fragment_depth: int = 0
    node_ids: set[str] = field(default_factory=set)
    call_nodes: list[tuple[str, int, str | None]] = field(default_factory=list)
    decisions: set[str] = field(default_factory=set)
    decision_id_counts: Counter[str] = field(default_factory=Counter)
    decision_edges: list[tuple[str | None, str]] = field(default_factory=list)
    render_stage: int = 0


class AuditParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.errors: list[str] = []
        self.id_counts: Counter[str] = Counter()
        self.diagrams: list[DiagramAudit] = []
        self.svg_stack: list[DiagramAudit] = []
        self.tag_stack: list[str] = []
        self.class_stack: list[set[str]] = []
        self.style_depth = 0
        self.style_text: list[str] = []
        self.has_html_ja = False
        self.has_page_title = False
        self.has_h1 = False
        self.title_phrases = 0
        self.has_main_contract = False
        self.explanation_mode: str | None = None
        self.has_page_header = False
        self.has_diagram_panel = False
        self.has_evidence_grid = False
        self.has_evidence_list = False
        self.evidence_cards = 0
        self.evidence_rows = 0
        self.evidence_section_cards = 0
        self.has_change_appendix = False
        self.has_change_file_list = False
        self.has_diff_summary = False
        self.has_diff_excerpt = False
        self.has_verification_list = False
        self.change_appendix_closed = False
        self.has_footer = False
        self.footer_after_appendix = False
        self.change_sections: set[str] = set()
        self.change_heading_text: dict[str, list[str]] = {role: [] for role in CHANGE_SECTION_TITLES}
        self.active_change_heading: str | None = None
        self.change_appendix_label_text: list[str] = []
        self.active_change_appendix_label = False
        self.is_template_sample = False
        self.csp_values: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        parent_tag = self.tag_stack[-1] if self.tag_stack else None
        attributes = {key: value or "" for key, value in attrs}
        classes = set(attributes.get("class", "").split())

        if tag in FORBIDDEN_TAGS:
            self.errors.append(f"禁止要素 <{tag}> がある")
        for name, value in attrs:
            if name.lower().startswith("on"):
                self.errors.append(f"event handler属性 {name} がある")
            if name.lower() == "style":
                self.errors.append("inline style属性がある")
            if name.lower() in {"src", "href", "poster", "action"}:
                uri = (value or "").strip()
                if uri.startswith("//") or URI_SCHEME_RE.match(uri):
                    self.errors.append(f"外部またはscheme付き参照 {name}={uri!r} がある")

        if tag == "html" and attributes.get("lang") == "ja":
            self.has_html_ja = True
        if tag == "title" and not self.svg_stack:
            self.has_page_title = True
        if tag == "h1":
            self.has_h1 = True
        if tag == "span" and "title-phrase" in classes and "h1" in self.tag_stack:
            self.title_phrases += 1
        if tag == "main" and attributes.get("data-explain-code") == "1":
            self.has_main_contract = True
            self.explanation_mode = attributes.get("data-explanation-mode")
            self.is_template_sample = attributes.get("data-template-sample") == "1"
        if "page-header" in classes:
            self.has_page_header = True
        if "diagram-panel" in classes:
            self.has_diagram_panel = True
        if "evidence-grid" in classes:
            self.has_evidence_grid = True
        if "evidence-list" in classes:
            self.has_evidence_list = True
        if "evidence-card" in classes:
            self.evidence_cards += 1
            if any("evidence-section" in ancestor for ancestor in self.class_stack):
                self.evidence_section_cards += 1
        if "evidence-row" in classes:
            self.evidence_rows += 1
        if "change-appendix" in classes:
            self.has_change_appendix = True
        in_change_appendix = "change-appendix" in classes or any("change-appendix" in ancestor for ancestor in self.class_stack)
        if tag == "p" and "section-label" in classes and self.class_stack and "change-appendix" in self.class_stack[-1]:
            self.active_change_appendix_label = True
        change_roles = set(CHANGE_SECTION_TITLES) & classes
        self.change_sections.update(change_roles)
        if in_change_appendix and ({"change-summary-grid", "change-block"} & classes):
            self.errors.append("変更補足にcardまたはcard gridがある")
        if tag == "h2":
            ancestor_roles = set().union(*(set(CHANGE_SECTION_TITLES) & ancestor for ancestor in self.class_stack))
            if len(ancestor_roles) == 1:
                self.active_change_heading = next(iter(ancestor_roles))
            elif in_change_appendix:
                self.errors.append(".change-appendix内に役割のないカテゴリ見出しがある")
        appendix_components = {"change-file-list", "diff-summary", "diff-excerpt", "verification-list"}
        if appendix_components & classes and not in_change_appendix:
            self.errors.append("変更補足の要素が.change-appendixの外にある")
        if "change-file-list" in classes:
            self.has_change_file_list = True
        if "diff-summary" in classes:
            self.has_diff_summary = True
        if "diff-excerpt" in classes:
            self.has_diff_excerpt = True
        if "verification-list" in classes:
            self.has_verification_list = True
        if tag == "footer":
            self.has_footer = True
            self.footer_after_appendix = self.change_appendix_closed
        elif parent_tag == "main" and self.change_appendix_closed:
            self.errors.append(".change-appendixとfooterの間に別の要素がある")
        if tag == "meta" and attributes.get("http-equiv", "").lower() == "content-security-policy":
            self.csp_values.append(attributes.get("content", ""))
        if tag == "style":
            self.style_depth += 1

        element_id = attributes.get("id")
        if element_id:
            self.id_counts[element_id] += 1

        if tag == "svg" and "explain-diagram" in classes:
            aria = attributes.get("aria-labelledby", "").split()
            if attributes.get("role") != "img":
                self.errors.append("explain-diagramにrole=imgがない")
            audit = DiagramAudit(attributes.get("data-diagram-type"), aria, bool(attributes.get("viewbox", "").strip()))
            self.diagrams.append(audit)
            self.svg_stack.append(audit)

        if self.svg_stack:
            audit = self.svg_stack[-1]
            if parent_tag == "svg":
                audit.direct_children.append(tag)
                if tag == "title" and element_id:
                    audit.title_ids.append(element_id)
                if tag == "desc" and element_id:
                    audit.desc_ids.append(element_id)
            self._audit_diagram_element(audit, tag, attributes, classes)

        self.tag_stack.append(tag)
        self.class_stack.append(classes)

    def _audit_diagram_element(self, audit: DiagramAudit, tag: str, attributes: dict[str, str], classes: set[str]) -> None:
        if {"diagram-zone", "swimlane"} & classes:
            if audit.render_stage > 0:
                self.errors.append(f"{audit.diagram_type}のzone/laneがedgeより後にある")
        if "diagram-node" in classes:
            audit.nodes += 1
            audit.seen_node = True
            audit.render_stage = 2
            if "is-focal" in classes:
                audit.focal_nodes += 1
            roles = NODE_ROLES.get(audit.diagram_type or "", set()) & classes
            if not roles and audit.diagram_type in NODE_ROLES:
                self.errors.append(f"{audit.diagram_type}のdiagram-nodeにrole classがない")
        if "diagram-edge" in classes:
            audit.edges += 1
            audit.render_stage = max(audit.render_stage, 1)
            if audit.seen_node:
                audit.edge_after_node = True
            if tag == "path" and not path_is_orthogonal(
                attributes.get("d", ""),
                allow_self_loop=audit.diagram_type == "state" and "state-self-loop" in classes,
            ):
                self.errors.append(f"{audit.diagram_type}に直交規則外のdiagram-edge pathがある")
            if tag == "line":
                x1, x2 = attributes.get("x1"), attributes.get("x2")
                y1, y2 = attributes.get("y1"), attributes.get("y2")
                if x1 != x2 and y1 != y2:
                    self.errors.append(f"{audit.diagram_type}に斜めlineのdiagram-edgeがある")
        if "is-focal" in classes and ({"diagram-node", "diagram-edge"} & classes):
            audit.focal += 1
        for role in COUNTED_ROLES:
            if role in classes:
                audit.roles[role] += 1
        if "lifeline" in classes and "sequence-lifeline" not in classes:
            audit.roles["sequence-lifeline"] += 1
        if "frame" in classes or "sequence-frame" in classes or "sequence-fragment" in classes:
            if "sequence-fragment" not in classes:
                audit.roles["sequence-fragment"] += 1
            audit.fragment_depth += 1
            audit.max_fragment_depth = max(audit.max_fragment_depth, audit.fragment_depth)
        if audit.diagram_type == "flowchart" and "flow-decision" in classes:
            node_id = attributes.get("data-node-id")
            if node_id:
                audit.decisions.add(node_id)
                audit.decision_id_counts[node_id] += 1
            else:
                self.errors.append("flow-decisionにdata-node-idがない")
        if audit.diagram_type == "flowchart" and "decision-edge" in classes:
            audit.decision_edges.append((attributes.get("data-from"), attributes.get("data-label", "").strip()))
        if audit.diagram_type == "call-tree" and "diagram-node" in classes:
            node_id = attributes.get("data-node-id", "")
            try:
                depth = int(attributes.get("data-depth", ""))
            except ValueError:
                depth = -1
            audit.call_nodes.append((node_id, depth, attributes.get("data-parent") or None))
            if node_id:
                audit.node_ids.add(node_id)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self.handle_starttag(tag, attrs)
        self.handle_endtag(tag)

    def handle_endtag(self, tag: str) -> None:
        classes = self.class_stack.pop() if self.class_stack else set()
        if self.tag_stack:
            self.tag_stack.pop()
        if tag == "style" and self.style_depth:
            self.style_depth -= 1
        if self.svg_stack and ({"frame", "sequence-frame", "sequence-fragment"} & classes):
            self.svg_stack[-1].fragment_depth -= 1
        if tag == "svg" and self.svg_stack:
            self.svg_stack.pop()
        if tag == "h2":
            self.active_change_heading = None
        if tag == "p" and self.active_change_appendix_label:
            self.active_change_appendix_label = False
        if "change-appendix" in classes:
            self.change_appendix_closed = True

    def handle_data(self, data: str) -> None:
        if self.style_depth:
            self.style_text.append(data)
        if self.active_change_heading:
            self.change_heading_text[self.active_change_heading].append(data)
        if self.active_change_appendix_label:
            self.change_appendix_label_text.append(data)


def parse_csp(value: str) -> dict[str, tuple[str, ...]] | None:
    result: dict[str, tuple[str, ...]] = {}
    for part in value.split(";"):
        tokens = part.split()
        if not tokens:
            continue
        if tokens[0] in result:
            return None
        result[tokens[0]] = tuple(tokens[1:])
    return result


def css_contract_errors(css: str, selector: str, name: str, expected: dict[str, str]) -> list[str]:
    matched_rules: list[dict[str, list[str]]] = []
    for selector_text, body in CSS_RULE_RE.findall(css):
        selectors = {candidate.strip() for candidate in selector_text.split(",")}
        if selector not in selectors:
            continue
        declarations: dict[str, list[str]] = {}
        for raw_declaration in body.split(";"):
            property_name, separator, value = raw_declaration.partition(":")
            if not separator:
                continue
            normalized_value = re.sub(r"\s*!\s*important\b", " !important", value.strip().lower())
            declarations.setdefault(property_name.strip().lower(), []).append(normalized_value)
        matched_rules.append(declarations)
    if len(matched_rules) != 1:
        return [f"変更モードの共通CSS契約 {name} のrule数が{len(matched_rules)}。1個だけ必要"]
    errors: list[str] = []
    declarations = matched_rules[0]
    for property_name, expected_value in expected.items():
        actual_values = declarations.get(property_name, [])
        if actual_values != [expected_value]:
            errors.append(
                f"変更モードの共通CSS契約 {name} の{property_name}が{actual_values!r}。{expected_value!r}を1回だけ指定する"
            )
    return errors


def css_selector_usage_errors(css: str, selector: str, name: str, allowed: set[str]) -> list[str]:
    errors: list[str] = []
    selector_token = re.compile(rf"{re.escape(selector)}(?![\w-])")
    for selector_text, _ in CSS_RULE_RE.findall(css):
        for candidate in (item.strip() for item in selector_text.split(",")):
            if selector_token.search(candidate) and candidate not in allowed:
                errors.append(f"変更モードの共通CSS契約 {name} を未許可selector {candidate!r} が上書きできる")
    return errors


def css_priority_errors(css: str) -> list[str]:
    errors: list[str] = []
    for selector_text, body in CSS_RULE_RE.findall(css):
        selectors = {candidate.strip() for candidate in selector_text.split(",")}
        for raw_declaration in body.split(";"):
            property_name, separator, value = raw_declaration.partition(":")
            if not separator or not re.search(r"!\s*important\b", value, re.IGNORECASE):
                continue
            normalized_property = property_name.strip().lower()
            normalized_value = re.sub(r"\s*!\s*important\s*$", "", value.strip().lower())
            if len(selectors) != 1:
                errors.append(f"!importantを複数selector {sorted(selectors)!r} へ指定している")
                continue
            selector = next(iter(selectors))
            expected_value = IMPORTANT_CONTRACTS.get(selector, {}).get(normalized_property)
            if normalized_value != expected_value:
                errors.append(f"未許可の!important {selector} {normalized_property}: {normalized_value}")
    return errors


def css_selector_safety_errors(css: str) -> list[str]:
    errors: list[str] = []
    for selector_text, _ in CSS_RULE_RE.findall(css):
        for selector in (candidate.strip() for candidate in selector_text.split(",")):
            if "[" in selector or "]" in selector:
                errors.append(f"CSS selectorにattribute selectorがある: {selector!r}")
            if "#" in selector:
                errors.append(f"CSS selectorにID selectorがある: {selector!r}")
            if ":" in selector and selector != ":root":
                errors.append(f"CSS selectorに未許可のpseudo selectorがある: {selector!r}")
    return errors


def path_is_orthogonal(path: str, *, allow_self_loop: bool = False) -> bool:
    tokens = PATH_TOKEN_RE.findall(path)
    residue = PATH_TOKEN_RE.sub("", path)
    if not tokens or residue.replace(",", "").strip():
        return False
    commands = {token.upper() for token in tokens if token.isalpha()}
    allowed = {"M", "H", "V"}
    if allow_self_loop:
        allowed |= {"C", "Q", "A"}
    if not commands <= allowed or tokens[0].upper() != "M":
        return False
    index = 0
    while index < len(tokens):
        command = tokens[index].upper()
        if not tokens[index].isalpha():
            return False
        index += 1
        start = index
        while index < len(tokens) and not tokens[index].isalpha():
            index += 1
        count = index - start
        if command == "M" and count != 2:
            return False
        if command in {"H", "V"} and count < 1:
            return False
        if command == "C" and count != 6:
            return False
        if command == "Q" and count != 4:
            return False
        if command == "A" and count != 7:
            return False
    return True


def diagram_errors(diagram: DiagramAudit, index: int) -> list[str]:
    errors: list[str] = []
    prefix = f"diagram {index}"
    diagram_type = diagram.diagram_type or ""
    if diagram_type not in ALLOWED_DIAGRAM_TYPES:
        errors.append(f"{prefix}のdata-diagram-typeが未対応: {diagram.diagram_type!r}")
    if not diagram.has_view_box:
        errors.append(f"{prefix}にviewBoxがない")
    if diagram.direct_children[:2] != ["title", "desc"]:
        errors.append(f"{prefix}の先頭の直下要素が<title><desc>ではない")
    if len(diagram.title_ids) != 1 or len(diagram.desc_ids) != 1:
        errors.append(f"{prefix}にはid付きの直下<title>と<desc>が1個ずつ必要")
    elif diagram.aria_ids != [diagram.title_ids[0], diagram.desc_ids[0]]:
        errors.append(f"{prefix}のaria-labelledbyが自身のtitle/descと一致しない")
    node_limit = TYPE_NODE_LIMITS.get(diagram_type, 9)
    if diagram.nodes > node_limit:
        errors.append(f"{prefix}のnodeが{diagram.nodes}個ある。{diagram_type}の上限は{node_limit}")
    if diagram.edges > 12:
        errors.append(f"{prefix}のedgeが{diagram.edges}個ある。上限は12")
    if diagram.focal > 2:
        errors.append(f"{prefix}のfocal要素が{diagram.focal}個ある。上限は2")
    if diagram.edge_after_node:
        errors.append(f"{prefix}はnodeより後にedgeを描いている")
    for role, limit in ROLE_LIMITS.get(diagram_type, {}).items():
        if diagram.roles[role] > limit:
            errors.append(f"{prefix}の{role}が{diagram.roles[role]}個ある。上限は{limit}")
    if diagram_type == "sequence" and diagram.max_fragment_depth > 1:
        errors.append(f"{prefix}のsequence fragment nestingが{diagram.max_fragment_depth}ある。上限は1")
    if diagram_type == "flowchart":
        duplicates = [node_id for node_id, count in diagram.decision_id_counts.items() if count > 1]
        if duplicates:
            errors.append(f"{prefix}のflow decision data-node-idが重複している: {', '.join(sorted(duplicates))}")
        for decision in diagram.decisions:
            outgoing = [label for source, label in diagram.decision_edges if source == decision]
            if len(outgoing) < 2 or any(not label for label in outgoing):
                errors.append(f"{prefix}のdecision {decision!r}にlabel付き分岐edgeが2本ない")
    if diagram_type == "state":
        if diagram.roles["state-start"] != 1 or diagram.roles["state-end"] != 1:
            errors.append(f"{prefix}のstate-start/state-endは1個ずつ必要")
        if diagram.focal_nodes > 1:
            errors.append(f"{prefix}のfocal stateが{diagram.focal_nodes}個ある。上限は1")
    if diagram_type == "call-tree":
        errors.extend(call_tree_errors(diagram, prefix))
    return errors


def call_tree_errors(diagram: DiagramAudit, prefix: str) -> list[str]:
    errors: list[str] = []
    ids = [node_id for node_id, _, _ in diagram.call_nodes]
    if any(not node_id for node_id in ids) or len(ids) != len(set(ids)):
        errors.append(f"{prefix}のcall-tree nodeには一意なdata-node-idが必要")
    roots = [(node_id, depth) for node_id, depth, parent in diagram.call_nodes if parent is None]
    if len(roots) != 1 or (roots and roots[0][1] != 0):
        errors.append(f"{prefix}のcall-tree rootはdata-depth=0で1個必要")
    children = Counter(parent for _, _, parent in diagram.call_nodes if parent)
    if any(count > 3 for count in children.values()):
        errors.append(f"{prefix}のcall-tree branchが上限3を超える")
    nodes = {node_id: (depth, parent) for node_id, depth, parent in diagram.call_nodes if node_id}
    root_id = roots[0][0] if len(roots) == 1 else None
    for node_id, depth, parent in diagram.call_nodes:
        if not 0 <= depth <= 5:
            errors.append(f"{prefix}のcall-tree node {node_id!r}のdepthが0..5外")
        if parent and parent not in diagram.node_ids:
            errors.append(f"{prefix}のcall-tree node {node_id!r}のparentが存在しない")
        if parent in nodes and depth != nodes[parent][0] + 1:
            errors.append(f"{prefix}のcall-tree node {node_id!r}のdepthがparentと連続しない")
        seen: set[str] = set()
        cursor: str | None = node_id
        while cursor and cursor in nodes and cursor not in seen:
            seen.add(cursor)
            cursor = nodes[cursor][1]
        if cursor in seen:
            errors.append(f"{prefix}のcall-tree node {node_id!r}が親循環を持つ")
        elif root_id and node_id != root_id and root_id not in seen:
            errors.append(f"{prefix}のcall-tree node {node_id!r}がrootへ到達しない")
    return errors


def validate_text(text: str, *, template: bool = False) -> list[str]:
    parser = AuditParser()
    try:
        parser.feed(text)
        parser.close()
    except Exception as error:
        return [f"HTMLを解析できない: {error}"]

    errors = list(parser.errors)
    required_structure = {
        "<html lang=ja>": parser.has_html_ja,
        "page <title>": parser.has_page_title,
        "<h1>": parser.has_h1,
        "main[data-explain-code=1]": parser.has_main_contract,
        ".page-header": parser.has_page_header,
        ".diagram-panel": parser.has_diagram_panel,
        ".evidence-gridまたは.evidence-list": parser.has_evidence_grid or parser.has_evidence_list,
    }
    errors.extend(f"必須構造 {name} がない" for name, present in required_structure.items() if not present)
    if parser.title_phrases == 0:
        errors.append("h1に.title-phraseがない")
    if parser.explanation_mode not in {"change", "design"}:
        errors.append("main[data-explanation-mode]はchangeまたはdesignが必要")
    if len(parser.csp_values) != 1 or parse_csp(parser.csp_values[0]) != EXPECTED_CSP:
        errors.append("CSPが規定のexact allowlistと一致しない")
    duplicates = sorted(element_id for element_id, count in parser.id_counts.items() if count > 1)
    errors.extend(f"id #{element_id} が重複している" for element_id in duplicates)

    css = "".join(parser.style_text)
    if REMOTE_CSS_RE.search(css):
        errors.append("CSSに外部取得につながる@importまたはurl()がある")
    for name, pattern in REQUIRED_CSS_PATTERNS.items():
        if not pattern.search(css):
            errors.append(f"共通CSS契約 {name} がない")
    for token, expected in EXPECTED_PALETTE.items():
        definitions = re.findall(rf"--{re.escape(token)}\s*:\s*([^;}}]+)", css, re.IGNORECASE)
        if len(definitions) != 1:
            errors.append(f"palette token --{token} の定義数が{len(definitions)}。1個だけ必要")
        elif definitions[0].strip().lower() != expected:
            errors.append(f"palette token --{token} が既定値 {expected} と一致しない")
    for name, pattern in FORBIDDEN_CSS_PATTERNS.items():
        if pattern.search(css):
            errors.append(f"禁止CSS {name} がある")
    errors.extend(css_priority_errors(css))
    errors.extend(css_selector_safety_errors(css))

    if not parser.diagrams:
        errors.append(".explain-diagramがない")
    if len(parser.diagrams) > 4:
        errors.append(f"diagramが{len(parser.diagrams)}個ある。上限は4")
    evidence_items = parser.evidence_cards + parser.evidence_rows
    if evidence_items > 8:
        errors.append(f"evidence itemが{evidence_items}個ある。上限は8")
    for index, diagram in enumerate(parser.diagrams, start=1):
        errors.extend(diagram_errors(diagram, index))

    if parser.explanation_mode == "change":
        change_structure = {
            ".change-appendix": parser.has_change_appendix,
            ".evidence-list": parser.has_evidence_list,
            ".change-file-list": parser.has_change_file_list,
            ".diff-summary": parser.has_diff_summary,
            ".diff-excerpt": parser.has_diff_excerpt,
            ".verification-list": parser.has_verification_list,
        }
        errors.extend(f"変更モードの必須構造 {name} がない" for name, present in change_structure.items() if not present)
        if parser.evidence_section_cards:
            errors.append("変更モードの.evidence-sectionに.evidence-cardがある")
        appendix_label = "".join(parser.change_appendix_label_text).strip()
        if appendix_label != "Change appendix":
            errors.append(f".change-appendixのsection labelが'Change appendix'ではない: {appendix_label!r}")
        for role, expected in CHANGE_SECTION_TITLES.items():
            if role not in parser.change_sections:
                errors.append(f"変更モードの必須section .{role} がない")
                continue
            actual = "".join(parser.change_heading_text[role]).strip()
            if actual != expected:
                errors.append(f".{role}のh2が{expected!r}ではない: {actual!r}")
        errors.extend(
            css_contract_errors(
                css,
                ".evidence-list",
                ".evidence-listの1列grid",
                {property_name: f"{value} !important" for property_name, value in IMPORTANT_CONTRACTS[".evidence-list"].items()},
            )
        )
        errors.extend(
            css_contract_errors(
                css,
                ".evidence-row",
                ".evidence-rowの全幅card",
                {property_name: f"{value} !important" for property_name, value in IMPORTANT_CONTRACTS[".evidence-row"].items()},
            )
        )
        errors.extend(
            css_selector_usage_errors(
                css,
                ".evidence-row",
                ".evidence-rowの全幅card",
                {".evidence-row", ".evidence-row h3", ".evidence-row p", ".evidence-row a", ".evidence-row code"},
            )
        )
        errors.extend(
            css_contract_errors(
                css,
                ".change-section",
                ".change-sectionの全幅card",
                {property_name: f"{value} !important" for property_name, value in IMPORTANT_CONTRACTS[".change-section"].items()},
            )
        )
        errors.extend(
            css_selector_usage_errors(
                css,
                ".change-section",
                ".change-sectionの全幅card",
                {".change-section", ".change-section + .change-section", ".change-section h2"},
            )
        )
        if not parser.has_footer:
            errors.append("変更モードにfooterがない")
        elif not parser.footer_after_appendix:
            errors.append("変更モードの.change-appendixがfooter直前にない")
    elif parser.has_change_appendix:
        errors.append("設計モードに.change-appendixがある")

    if template:
        if not parser.is_template_sample:
            errors.append("templateにdata-template-sample=1がない")
    elif parser.is_template_sample:
        errors.append("生成HTMLにdata-template-sample=1が残っている")
    return sorted(set(errors))


def fixture(diagram_type: str, body: str) -> str:
    return f'''<!doctype html><html lang="ja"><head><title>T</title>
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'; object-src 'none'">
    <style>:root{{color-scheme:light;--paper:#f1f4f6;--surface:#fbfdff;--surface-muted:#e5ebef;--ink:#202b38;--muted:#526273;--soft:#738395;--rule:#c5d0d8;--accent:#b84e68;--accent-soft:#f6e2e8;--runtime:#23705f;--runtime-soft:#ddf0ea;--inferred:#84651c;--inferred-soft:#f3ecd9;--link:#315f9b;--font-sans:system-ui,sans-serif}}.page-header{{max-width:1180px}}h1{{display:flex;flex-wrap:wrap;font-family:var(--font-sans);font-size:clamp(28px,4vw,44px);text-wrap:wrap;line-break:strict}}.title-phrase{{display:inline-block;white-space:nowrap}}.lede{{width:100%;max-width:none;text-wrap:wrap}}p{{overflow-wrap:anywhere}}.diagram-scroll{{overflow-x:auto}}.explain-diagram{{min-width:800px}}.diagram-edge{{marker-end:url(#arrow)}}</style></head><body>
    <main data-explain-code="1" data-explanation-mode="design"><header class="page-header"><h1><span class="title-phrase">H</span></h1></header><section class="diagram-panel">
    <svg class="explain-diagram" data-diagram-type="{diagram_type}" viewBox="0 0 100 100" role="img" aria-labelledby="t d"><title id="t">T</title><desc id="d">D</desc>{body}</svg></section>
    <section><div class="evidence-grid"></div></section><footer></footer></main></body></html>'''


def run_self_test() -> list[str]:
    valid = fixture("architecture", '<path class="diagram-edge" d="M 0 0 H 10"/><g class="diagram-node is-focal"></g>')
    failures: list[str] = []
    negative = {
        "追加CSP": valid.replace("object-src 'none'", "object-src 'none'; script-src 'unsafe-inline'"),
        "event handler": valid.replace("<main ", '<main onclick="x" '),
        "inline style": valid.replace('<g class="diagram-node is-focal"', '<g class="diagram-node is-focal" style="width:50%"'),
        "scheme付き参照": valid.replace("</main>", '<a href="javascript:x">x</a></main>'),
        "serif書体": valid.replace("</style>", "h2{font-family:serif}</style>"),
        "均等折返し": valid.replace("</style>", "h2{text-wrap:balance}</style>"),
        "見出しのpretty折返し": valid.replace("</style>", "h1{text-wrap:pretty}</style>"),
        "見出しのanywhere折返し": valid.replace("</style>", "h1{overflow-wrap:anywhere}</style>"),
        "ledeのpretty折返し": valid.replace("</style>", ".lede{text-wrap:pretty}</style>"),
        "lede幅の後退": valid.replace("max-width:none", "max-width:840px"),
        "title phrase欠落": valid.replace('<span class="title-phrase">H</span>', "H"),
        "header幅の後退": valid.replace("max-width:1180px", "max-width:1080px"),
        "palette逸脱": valid.replace("--inferred:#84651c", "--inferred:#000000"),
        "palette後置上書き": valid.replace("</style>", ":root{--inferred:#000000}</style>"),
        "important上書き": valid.replace("</style>", "article{width:50%!important}</style>"),
        "comment分割important": valid.replace("</style>", "article{width:50%!/**/important}</style>"),
        "escape important": valid.replace("</style>", r"article{width:50%!\69mportant}</style>"),
        "viewBox欠落": valid.replace(' viewBox="0 0 100 100"', ""),
        "aria取り違え": valid.replace('aria-labelledby="t d"', 'aria-labelledby="t other"').replace("</main>", '<h2 id="other">x</h2></main>'),
        "id重複": valid.replace("</main>", '<i id="t"></i></main>'),
        "title/desc順序": valid.replace('<title id="t">T</title><desc id="d">D</desc>', '<desc id="d">D</desc><title id="t">T</title>'),
        "edge後置": valid.replace('</g>', '</g><path class="diagram-edge" d="M 0 0 H 10"/>'),
        "斜めedge": valid.replace('d="M 0 0 H 10"', 'd="M 0 0 L 10 10"'),
        "曲線edge": valid.replace('d="M 0 0 H 10"', 'd="M 0 0 C 5 5 8 8 10 10"'),
        "暗黙斜めedge": valid.replace('d="M 0 0 H 10"', 'd="M 0 0 10 10"'),
        "斜めclose edge": valid.replace('d="M 0 0 H 10"', 'd="M 0 0 H 10 V 10 Z"'),
        "別図種のself-loop偽装": valid.replace('class="diagram-edge" d="M 0 0 H 10"', 'class="diagram-edge state-self-loop" d="M 0 0 C 5 5 8 8 10 10"'),
        "architecture zone超過": valid.replace("</svg>", '<g class="diagram-zone"></g>' * 4 + "</svg>"),
        "architecture zone後置": fixture("architecture", '<path class="diagram-edge" d="M 0 0 H 10"/><g class="diagram-zone"></g>'),
        "sequence fragment超過": fixture("sequence", '<g class="sequence-fragment"><g class="sequence-fragment"></g></g>'),
        "flowchart role欠落": fixture("flowchart", '<g class="diagram-node"></g>'),
        "flowchart decision ID重複": fixture("flowchart", '<path class="diagram-edge decision-edge" data-from="d" data-label="a" d="M 0 0 H 10"/><path class="diagram-edge decision-edge" data-from="d" data-label="b" d="M 0 4 H 10"/><g class="diagram-node flow-decision" data-node-id="d"></g><g class="diagram-node flow-decision" data-node-id="d"></g>'),
        "data-flow role欠落": fixture("data-flow", '<g class="diagram-node"></g>'),
        "state marker欠落": fixture("state", '<g class="diagram-node"></g>'),
        "call-tree depth超過": fixture("call-tree", '<g class="diagram-node" data-node-id="root" data-depth="6"></g>'),
        "call-tree 親循環": fixture("call-tree", '<g class="diagram-node" data-node-id="root" data-depth="0"></g><g class="diagram-node" data-node-id="a" data-depth="1" data-parent="b"></g><g class="diagram-node" data-node-id="b" data-depth="2" data-parent="a"></g>'),
        "swimlane lane超過": fixture("swimlane", '<g class="swimlane"></g>' * 6),
        "change-map changed超過": fixture("change-map", '<g class="diagram-node is-changed"></g>' * 6),
    }
    if validate_text(valid):
        failures.append("valid fixtureを拒否した")
    for name, sample in negative.items():
        if not validate_text(sample):
            failures.append(f"{name} fixtureを受理した")
    diagram_samples = [
        f'<svg class="explain-diagram" data-diagram-type="architecture" viewBox="0 0 100 100" role="img" aria-labelledby="t{index} d{index}"><title id="t{index}">T</title><desc id="d{index}">D</desc></svg>'
        for index in range(2, 6)
    ]
    extra_diagrams = "".join(diagram_samples)
    five_diagrams = valid.replace("</section>", f"{extra_diagrams}</section>", 1)
    if "diagramが5個ある。上限は4" not in validate_text(five_diagrams):
        failures.append("diagram上限fixtureを受理した")
    four_diagrams = valid.replace("</section>", f"{''.join(diagram_samples[:3])}</section>", 1)
    if validate_text(four_diagrams):
        failures.append("diagram 4個のfixtureを拒否した")
    change_without_appendix = valid.replace('data-explanation-mode="design"', 'data-explanation-mode="change"')
    if ".change-appendix" not in "\n".join(validate_text(change_without_appendix)):
        failures.append("変更補足欠落fixtureを受理した")
    appendix = '''<section class="change-appendix"><p class="section-label">Change appendix</p><section class="change-section change-files"><h2>変更ファイル</h2><ul class="change-file-list"></ul></section><section class="change-section diff-overview"><h2>差分概要</h2><p class="diff-summary"></p></section><section class="change-section diff-details"><h2>重要な差分</h2><pre class="diff-excerpt"></pre></section><section class="change-section verification-results"><h2>検証結果</h2><ul class="verification-list"></ul></section></section>'''
    card_css = ".evidence-list{display:grid!important;grid-template-columns:1fr!important}.evidence-row{width:100%!important;padding:20px!important;background:var(--surface)!important;border:1px solid var(--rule)!important;border-radius:6px!important}.change-section{display:grid!important;grid-template-columns:1fr!important;width:100%!important;padding:20px!important;background:var(--surface)!important;border:1px solid var(--rule)!important;border-radius:6px!important}"
    change_valid = change_without_appendix.replace('class="evidence-grid"', 'class="evidence-list"').replace("</style>", f"{card_css}</style>").replace("<footer>", f"{appendix}<footer>")
    if validate_text(change_valid):
        failures.append("正しい変更補足fixtureを拒否した")
    detached_component = change_valid.replace('class="diff-summary"', 'class="detached"').replace("</footer>", '</footer><p class="diff-summary"></p>')
    if "変更補足の要素が.change-appendixの外にある" not in validate_text(detached_component):
        failures.append("変更補足外の要素fixtureを受理した")
    appendix_after_footer = change_without_appendix.replace("</footer>", f"</footer>{appendix}")
    if "変更モードの.change-appendixがfooter直前にない" not in validate_text(appendix_after_footer):
        failures.append("footer後の変更補足fixtureを受理した")
    wrong_heading = change_valid.replace("<h2>差分概要</h2>", "<h2>一般的な変更確認</h2>")
    if ".diff-overviewのh2" not in "\n".join(validate_text(wrong_heading)):
        failures.append("変更補足の旧カテゴリ見出しfixtureを受理した")
    wrapped_category = change_valid.replace('<section class="change-appendix">', '<section class="change-appendix"><div><h2>一般的な変更確認</h2></div>')
    if ".change-appendix内に役割のないカテゴリ見出しがある" not in validate_text(wrapped_category):
        failures.append("wrapper内の旧カテゴリ見出しfixtureを受理した")
    missing_appendix_label = change_valid.replace('<p class="section-label">Change appendix</p>', "")
    if ".change-appendixのsection label" not in "\n".join(validate_text(missing_appendix_label)):
        failures.append("Change appendix label欠落fixtureを受理した")
    broken_card_contracts = {
        "evidence余白欠落": change_valid.replace("padding:20px!important", "padding:0!important", 1),
        "evidence全幅欠落": change_valid.replace(".evidence-row{width:100%!important", ".evidence-row{width:50%!important"),
        "evidence複数列": change_valid.replace(".evidence-list{display:grid!important;grid-template-columns:1fr!important", ".evidence-list{display:grid!important;grid-template-columns:repeat(2,1fr)!important"),
        "appendix余白欠落": change_valid.replace(".change-section{display:grid!important;grid-template-columns:1fr!important;width:100%!important;padding:20px!important", ".change-section{display:grid!important;grid-template-columns:1fr!important;width:100%!important;padding:0!important"),
        "appendix全幅欠落": change_valid.replace(".change-section{display:grid!important;grid-template-columns:1fr!important;width:100%!important", ".change-section{display:grid!important;grid-template-columns:1fr!important;width:50%!important"),
    }
    for name, broken_contract in broken_card_contracts.items():
        if not any("全幅card" in error or "1列grid" in error for error in validate_text(broken_contract)):
            failures.append(f"{name} fixtureを受理した")
    cascade_bypasses = {
        "evidence同一rule後置上書き": change_valid.replace(".evidence-row{width:100%!important;padding", ".evidence-row{width:100%!important;width:50%;padding"),
        "appendix同一rule後置上書き": change_valid.replace("padding:20px!important;background:var(--surface)!important", "padding:20px!important;padding:0;background:var(--surface)!important", 1),
        "evidence後置rule上書き": change_valid.replace("</style>", ".evidence-row{width:50%}</style>"),
        "appendix後置rule上書き": change_valid.replace("</style>", ".change-section{padding:0}</style>"),
        "evidence詳細selector上書き": change_valid.replace("</style>", ".page .evidence-row{width:50%}</style>"),
        "appendix詳細selector上書き": change_valid.replace("</style>", ".change-appendix .change-section{padding:0}</style>"),
    }
    for name, cascade_bypass in cascade_bypasses.items():
        if not any("全幅card" in error for error in validate_text(cascade_bypass)):
            failures.append(f"{name} fixtureを受理した")
    global_cascade_bypasses = {
        "evidence inline style": change_valid.replace("<footer>", '<article class="evidence-row" style="width:50%"></article><footer>'),
        "汎用important上書き": change_valid.replace("</style>", "article{width:50%!important}</style>"),
        "attribute selector上書き": change_valid.replace("</style>", '[class~="evidence-row"]{width:50%}</style>'),
        "汎用attribute selector上書き": change_valid.replace("</style>", "article[class]{width:50%}</style>"),
        "ID selector上書き": change_valid.replace("</style>", "#target article{width:50%}</style>"),
        "pseudo selector上書き": change_valid.replace("</style>", "article:first-of-type{width:50%}</style>"),
    }
    for name, cascade_bypass in global_cascade_bypasses.items():
        if not validate_text(cascade_bypass):
            failures.append(f"{name} fixtureを受理した")
    card_appendix = change_valid.replace('class="change-section change-files"', 'class="change-section change-files change-block"')
    if "変更補足にcardまたはcard gridがある" not in validate_text(card_appendix):
        failures.append("変更補足のcard fixtureを受理した")
    sample = valid.replace('data-explain-code="1"', 'data-explain-code="1" data-template-sample="1"')
    if not validate_text(sample):
        failures.append("template sample残存fixtureを受理した")
    if validate_text(sample, template=True):
        failures.append("template fixtureを拒否した")
    return failures


def main() -> int:
    argument_parser = argparse.ArgumentParser()
    argument_parser.add_argument("path", nargs="?", type=Path)
    argument_parser.add_argument("--template", action="store_true")
    argument_parser.add_argument("--self-test", action="store_true")
    args = argument_parser.parse_args()
    if args.self_test:
        errors = run_self_test()
        if errors:
            for error in errors:
                print(f"ERROR: {error}", file=sys.stderr)
            return 1
        print("validate_html self-test passed")
        return 0
    if args.path is None:
        argument_parser.error("pathまたは--self-testが必要")
    errors = validate_text(args.path.read_text(encoding="utf-8"), template=args.template)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"OK: {args.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
