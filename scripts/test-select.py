#!/usr/bin/env python3
"""Choose the window tests a change needs, from its diff against the merge base with origin/main.

Each declaration the change touches is followed up the references in the app and the window tests'
helpers until window tests name it, and those nearest tests run; Core is left to its own tests.
Changed window tests run themselves. Changes to the test scripts, the package or the chat
renderer's assets run every window test. Deploy runs the full suite, so a dependency this misses
is still caught before an install.

  test-select.py [--base <commit>] [--head <commit>] [--alone <test>] [--explain]
prints `all`, `none` or a `swift test --filter` expression for the window tests (leaving out the
--alone test, which runs in its own process), then on lines of their own `alone` when that test is
needed and `release` when a changed declaration uses a task group (Swift 6.4's optimizer bug); with
--explain, why, on stderr. Without --head it compares the working tree, untracked files included;
BOTCHU_TEST_BASE stands in for --base (a stacked branch's parent).
"""
from collections import defaultdict
from pathlib import Path
import os
import re
import subprocess
import sys

CORE = "macOS/Sources/BotChuCore/"
SOURCES = ("macOS/Sources/BotChu/", CORE)
WINDOW_TESTS = "macOS/Tests/BotChuRenderingTests/"
EVERYTHING = ("macOS/Package.swift", "macOS/Package.resolved", "macOS/test.sh", "scripts/test.sh",
              "scripts/test-support.sh", "scripts/test-select.py", "scripts/coord/",
              "macOS/Sources/BotChu/Resources/")
SUITE = r"BotChuRenderingTests\.RenderingTests"
DEPTH = 10  # SwiftUI views nest deeply: a row can be six views below what a test hosts
HUB = 25  # a name more window tests use than this (AppModel, send) leads nowhere specific
TYPES = {"struct", "class", "enum", "protocol", "actor", "extension"}
DECLARATION = re.compile(
    r"^(?P<indent> *)(?:@[\w.]+(?:\([^)]*\))? +)*"
    r"(?:(?:public|private|fileprivate|internal|open|static|final|override|mutating|nonisolated|"
    r"lazy|weak|unowned|convenience|required|indirect|dynamic|package|class(?= +(?:func|var)))"
    r"(?:\([^)]*\))? +)*"
    r"(?P<kind>func|var|let|init|subscript|case|struct|class|enum|protocol|actor|extension|typealias)"
    r"\b(?: +(?P<name>[A-Za-z_]\w*))?")
WORD = re.compile(r"[A-Za-z_]\w*")
IDLE = re.compile(r"^\s*(?://.*|[{}()\[\],]*)$")  # blank lines, comments and lone brackets
TASK_GROUP = re.compile(r"with(?:Throwing)?(?:Discarding)?TaskGroup")
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", re.M)


class Declaration:
    def __init__(self, path, kind, name, owner, first, last, test, words):
        self.path, self.kind, self.name, self.owner = path, kind, name, owner
        self.first, self.last, self.test, self.words = first, last, test, words


def parse(path, text):
    """Top-level and type-level declarations with their 1-based line spans, by indentation."""
    lines = text.split("\n")
    found, types = [], []  # types: (indent, name) of the enclosing type declarations
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip():
            indent = len(line) - len(line.lstrip(" "))
            while types and indent <= types[-1][0] and not line.lstrip().startswith("}"):
                types.pop()
        match = DECLARATION.match(line)
        if not match:
            i += 1
            continue
        depth = len(match.group("indent"))
        kind = match.group("kind")
        name = "init" if kind == "init" else match.group("name")
        last = i
        for j in range(i + 1, len(lines)):
            stripped = lines[j].strip()
            if not stripped:
                continue
            k = len(lines[j]) - len(lines[j].lstrip(" "))
            if k < depth or (k == depth and not stripped.startswith(("}", ")", "]", "."))):
                break
            last = j
        previous = next((lines[j].strip() for j in range(i - 1, -1, -1) if lines[j].strip()), "")
        test = kind == "func" and ("@Test" in line or previous.startswith("@Test"))
        words = set()  # a type's own line: its members have theirs
        for body in lines[i:i + 1] if kind in TYPES else lines[i:last + 1]:
            words.update(WORD.findall(body.split("//", 1)[0]))
        found.append(Declaration(path, kind, name, types[-1][1] if types else None,
                                 i + 1, last + 1, test, words))
        if kind in TYPES:
            types.append((depth, name))
            i += 1  # its members are declarations of their own
        else:
            i = last + 1  # what is inside a member is the member's
    return found


def changed_lines(status, diff, old_text, new_text):
    """(old, new) 1-based line numbers a change touches; a removal counts where it was."""
    if status == "A":
        return set(), set(range(1, new_text.count("\n") + 2))
    if status == "D":
        return set(range(1, old_text.count("\n") + 2)), set()
    old, new = set(), set()
    for match in HUNK.finditer(diff):
        a, b, c, d = (int(g) if g is not None else 1 for g in match.groups())
        old.update(range(a, a + b))
        new.update(range(c, c + d) if d else [max(c, 1)])
    return old, new


def touched(declarations, lines, text):
    """The innermost declaration around each changed line that is more than a comment or bracket."""
    rows = text.split("\n")
    hit = set()
    for line in lines:
        if 0 < line <= len(rows) and not IDLE.match(rows[line - 1]):
            around = [d for d in declarations if d.first <= line <= d.last]
            if around:
                hit.add(max(around, key=lambda d: d.first))
    return hit


class Graph:
    def __init__(self, files):
        every = [d for declarations in files.values() for d in declarations]
        self.window = [d for d in every if d.test]
        # Core is covered by its own tests: only the app and the tests' helpers lead to window tests.
        self.users = [d for d in every if not d.test and not d.path.startswith(CORE)]
        self.owners, self.used, self.named = defaultdict(set), defaultdict(int), defaultdict(int)
        for d in every:
            if d.kind != "extension" and d.name and not d.test:
                self.owners[d.name].add(d.owner)
            for word in d.words:
                self.used[word] += 1
                self.named[word] += d.test

    def key(self, d):
        """The name that reaches a declaration: its own, or its type's when that is more specific."""
        if d.kind in ("init", "subscript") or d.name in (None, "body"):
            return d.owner
        if len(self.owners[d.name]) <= 1 or d.owner is None:
            return d.name
        return min((d.name, d.owner), key=lambda name: self.used[name])

    def nearest(self, origin, explain):
        """The window tests that name the origin, or else name what uses it, nearest first."""
        start = self.key(origin)
        if not start:
            return set()
        frontier, seen, chain = {start}, {start}, start
        for _ in range(DEPTH):
            hits = {t.name for t in self.window if t.words & frontier}
            if hits:
                explain(f"{chain} -> {len(hits)} tests")
                return hits
            users = {self.key(d) for d in self.users if d.words & frontier} - seen - {None}
            seen |= users
            frontier = {name for name in users if self.named[name] <= HUB}
            if not frontier:
                explain(f"{chain}: reaches only names most window tests use" if users
                        else f"{chain}: no window test uses it")
                return set()
            chain += " -> " + ", ".join(sorted(frontier)[:3]) + ("…" if len(frontier) > 3 else "")
        explain(f"{start}: no window test within {DEPTH} references")
        return set()


def select(changes, files, read_old, read_new, diff):
    """changes: [(status, path)]; files: path -> declarations at the head.
    Returns ("all" or a set of window test names, reasons, whether Release tests are needed)."""
    reasons, release, tests, origins = [], False, set(), []
    for status, path in changes:
        if path.endswith(("/SensitiveInput.swift", "/SensitiveInputTests.swift")):
            release = True
            reasons.append(f"{path}: secure input must also pass optimized validation")
        if path.startswith(EVERYTHING):
            return "all", [f"{path}: test scripts, package or renderer assets"], True
        if not path.endswith(".swift") or not path.startswith(SOURCES + (WINDOW_TESTS,)):
            continue
        old_text = read_old(path) if status != "A" else ""
        new_text = read_new(path) if status != "D" else ""
        old_lines, new_lines = changed_lines(status, diff(path), old_text, new_text)
        for text, lines in ((old_text, old_lines), (new_text, new_lines)):
            for declaration in touched(parse(path, text), lines, text):
                if path.startswith(SOURCES) and any(TASK_GROUP.fullmatch(w) for w in declaration.words):
                    release = True
                if declaration.test:
                    tests.add(declaration.name)
                    reasons.append(f"{path}: changed test {declaration.name}")
                elif not (status == "A" and declaration.kind == "extension"):
                    origins.append(declaration)
    graph = Graph(files)
    done = set()
    for origin in sorted(origins, key=lambda d: (d.path, d.first)):
        if (origin.path, origin.kind, origin.name, origin.owner) in done:
            continue
        done.add((origin.path, origin.kind, origin.name, origin.owner))
        tests |= graph.nearest(origin, lambda reason: reasons.append(f"{origin.path}: {reason}"))
    existing = {d.name for d in graph.window}
    return tests & existing, reasons, release


def filter_expression(names):
    return SUITE + "/(" + "|".join(sorted(names)) + r")\("


def report(selection, release, alone):
    """The lines macOS/test.sh reads: the window tests, then `alone` and `release` when needed."""
    lines = []
    if selection == "all":
        lines.append("all")
    else:
        rest = selection - {alone}
        lines.append(filter_expression(rest) if rest else "none")
    if alone and (selection == "all" or alone in selection):
        lines.append("alone")
    if release:
        lines.append("release")
    return lines


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout


def main(arguments):
    def option(name):
        return arguments[arguments.index(name) + 1] if name in arguments else None
    root = Path(git("rev-parse", "--show-toplevel").strip())
    base = option("--base") or os.environ.get("BOTCHU_TEST_BASE") or \
        git("merge-base", "HEAD", "origin/main").strip()
    head = option("--head")
    span = [base, head] if head else [base]
    changes = [(line[0], line.split("\t", 1)[1])
               for line in git("diff", "--name-status", "--no-renames", *span).splitlines()]
    untracked = [] if head else git("ls-files", "--others", "--exclude-standard").splitlines()
    changes += [("A", path) for path in untracked]

    def read_old(path):
        shown = subprocess.run(["git", "show", f"{base}:{path}"], capture_output=True, text=True)
        return shown.stdout if shown.returncode == 0 else ""

    def read_new(path):
        if head:
            return git("show", f"{head}:{path}")
        file = root / path
        return file.read_text() if file.is_file() else ""

    def diff(path):
        return git("diff", "-U0", "--no-color", *span, "--", path)

    paths = git("ls-tree", "-r", "--name-only", head).splitlines() if head else \
        git("ls-files", "--cached", "--others", "--exclude-standard").splitlines()
    files = {path: parse(path, read_new(path)) for path in paths
             if path.endswith(".swift") and path.startswith(SOURCES + (WINDOW_TESTS,))}
    selection, reasons, release = select(changes, files, read_old, read_new, diff)
    if "--explain" in arguments:
        for reason in dict.fromkeys(reasons):
            print(f"select: {reason}", file=sys.stderr)
    print("\n".join(report(selection, release, option("--alone"))))


if __name__ == "__main__":
    main(sys.argv[1:])
