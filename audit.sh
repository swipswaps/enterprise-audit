#!/usr/bin/env bash
# ==============================================================================
# Enterprise Audit Tool (v48.0)
# ==============================================================================
# Invariants: I1–I4. No `sed`. No `2>/dev/null`. No `>/dev/null`.
#
# Exit codes:
#   0  PASS (no defect, no policy violation)
#   1  FAIL (real defect: broken tests, or coverage below floor)
#   2  FATAL (setup error: unwritable log, unresolvable rebase)
#   3  POLICY_FAIL (REQUIRE_TESTS=1 and no runnable suite)
# ==============================================================================

if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "${0}" ]]; then
    echo "ERROR: This script must be executed, not sourced." >&2
    echo "Please run it as: ./$(basename "${BASH_SOURCE[0]}")" >&2
    return 2
fi

set -uo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"

run_with_timeout() {
    local duration="$1"; shift
    if command -v timeout; then timeout "$duration" "$@"
    else echo "[WARNING] 'timeout' not found; running without time limit." >&2; "$@"; fi
}

grep_py() {
    local pattern="$1"; shift
    find . -type f -name "*.py" \
        -not -path "*/.git/*" -not -path "*/venv/*" -not -path "*/.venv/*" \
        -not -path "*/node_modules/*" -not -path "*/__pycache__/*" \
        -print0 | xargs -0 grep -n "$pattern" "$@"
}

run_self_test() {
    local OK_N=0 BAD_N=0 SKIP_N=0
    BASE="$(mktemp -d -t audit_selftest.XXXXXX || mktemp -d)"
    SELFTEST_REPORTS="$(pwd)/selftest_reports"
    rm -rf "$SELFTEST_REPORTS"
    mkdir -p "$SELFTEST_REPORTS"
    trap 'rm -rf "${BASE:-}"; rm -f ./.coverage ./.coverage.*' EXIT

    echo "================================================================================"
    echo "  SELF-TEST — verdict must match ground truth (I1–I4). Base: $BASE"
    echo "  Reports preserved in: $SELFTEST_REPORTS"
    echo "================================================================================"

    run_case() {
        local label="$1" dir="$2" exp_rc="$3" pat="$4"; shift 4
        local out rc verdict ok="OK"
        local env_args=()
        for arg in "$@"; do env_args+=("$arg"); done
        # Persistent log per case (paths printed by the audit remain valid after run)
        local slug report_path
        slug="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '_')"
        report_path="$SELFTEST_REPORTS/${slug}.txt"
        out="$(cd "$dir" && env AUDIT_SKIP_PULL=1 AUDIT_FORCE_NO_COV=1 \
               LOG_FILE="$report_path" \
               "${env_args[@]}" bash "$SCRIPT_PATH" 2>&1)"
        rc=$?
        verdict="$(printf '%s\n' "$out" | grep -oE 'AUDIT VERDICT:.*' | head -n1)"
        if ! printf '%s\n' "$out" | grep -q 'AUDIT VERDICT:'; then
            ok="BAD(no verdict = crash)"
        elif [ "$rc" -ne "$exp_rc" ]; then
            ok="BAD(rc=$rc want $exp_rc)"
        elif ! printf '%s\n' "$out" | grep -qiE "$pat"; then
            ok="BAD(missing /$pat/)"
        fi
        if [ "$ok" = "OK" ]; then
            OK_N=$((OK_N + 1))
            printf '  [OK]  %-46s rc=%s  %s\n' "$label" "$rc" "${verdict:-<none>}"
        else
            BAD_N=$((BAD_N + 1))
            printf '  [BAD] %-46s rc=%s  %s\n' "$label" "$rc" "${verdict:-<none>}"
            printf '         reason: %s\n' "$ok"
            printf '%s\n' "$out" | tail -n 6 | awk '{print "         | " $0}'
        fi
    }

    ensure_pytest_cov() {
        local venv_dir="$1"
        if python3 -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('pytest') and importlib.util.find_spec('pytest_cov') else 1)"; then
            echo "  [INFO] pytest-cov available in system Python."; return 0
        fi
        echo "  [INFO] pytest-cov not found – creating temporary venv..."
        python3 -m venv "$venv_dir" || return 1
        # shellcheck source=/dev/null
        source "$venv_dir/bin/activate"
        pip install --quiet pytest pytest-cov || return 1
        deactivate
        echo "  [INFO] pytest-cov installed in temporary venv."
        return 0
    }

    local d

    d="$BASE/A_pass"; mkdir -p "$d"
    cat > "$d/test_ok.py" <<'PASSEOF'
import unittest
class TestMath(unittest.TestCase):
    def test_math(self):
        self.assertEqual(1 + 1, 2)
PASSEOF
    run_case "A clean + passing suite" "$d" 0 'VERDICT: PASS'

    d="$BASE/B_fail"; mkdir -p "$d"
    cat > "$d/test_bad.py" <<'FAILEOF'
import unittest
class TestBroken(unittest.TestCase):
    def test_broken(self):
        self.assertEqual(1 + 1, 3)
FAILEOF
    run_case "B real failing suite -> FAIL rc=1" "$d" 1 'VERDICT: FAIL'

    d="$BASE/C_skip"; mkdir -p "$d/tests"
    cat > "$d/tests/conftest.py" <<'CONFEOF'
# Fixtures only
CONFEOF
    run_case "C conftest-only (0 collected)" "$d" 0 'test SKIP'

    d="$BASE/C2_policy"; mkdir -p "$d/tests"
    cat > "$d/tests/conftest.py" <<'CONF2EOF'
# conftest only
CONF2EOF
    run_case "C2 no-tests + REQUIRE_TESTS=1 -> POLICY_FAIL rc=3" "$d" 3 'VERDICT: POLICY_FAIL' \
        AUDIT_REQUIRE_TESTS=1

    d="$BASE/D_nested"; mkdir -p "$d/tests/unit/deep"
    cat > "$d/tests/unit/deep/test_deep.py" <<'NESTEOF'
import unittest
class TestDeep(unittest.TestCase):
    def test_deep_pass(self):
        self.assertEqual("ok", "ok")
NESTEOF
    run_case "D passing suite nested 3 deep" "$d" 0 'VERDICT: PASS'

    d="$BASE/E_url"; mkdir -p "$d"
    cat > "$d/app.py" <<'URLEOF'
HEALTHCHECK = "http://example.invalid/health"

def test_placeholder():
    assert True
URLEOF
    run_case "E URL fetched (not line number)" "$d" 0 'example\.invalid/health'

    d="$BASE/F1_nogit"; mkdir -p "$d"
    cat > "$d/test_ok.py" <<'F1EOF'
import unittest
class TestPass(unittest.TestCase):
    def test_pass(self):
        self.assertTrue(True)
F1EOF
    run_case "F1 no git -> section SKIP, verdict OK" "$d" 0 'Not inside a git repository' \
        AUDIT_FORCE_NO_GIT=1

    d="$BASE/F2_nocurl"; mkdir -p "$d"
    cat > "$d/app.py" <<'F2EOF'
URL = "http://example.invalid/x"
def test_pass():
    assert True
F2EOF
    run_case "F2 no curl -> URL check SKIP" "$d" 0 'curl not installed' \
        AUDIT_FORCE_NO_CURL=1

    d="$BASE/F3_nopytest"; mkdir -p "$d"
    cat > "$d/test_ok.py" <<'F3EOF'
import unittest
class TestFallback(unittest.TestCase):
    def test_pass(self):
        self.assertEqual(2 * 2, 4)
F3EOF
    run_case "F3 no pytest -> fallback PASS" "$d" 0 'VERDICT: PASS' \
        AUDIT_FORCE_NO_PYTEST=1

    COV_VENV="$BASE/venv_cov"
    if ensure_pytest_cov "$COV_VENV"; then
        [ -d "$COV_VENV/bin" ] && export PATH="$COV_VENV/bin:$PATH"
        d="$BASE/G_cov"; mkdir -p "$d"
        cat > "$d/mymod.py" <<'MODEOF'
def covered():
    return 1

def uncovered_a():
    x = 1; y = 2; z = 3
    return x + y + z

def uncovered_b():
    a = 10; b = 20
    if a > b:
        return a
    return b
MODEOF
        cat > "$d/test_partial.py" <<'CTESTEOF'
import mymod
def test_only_covered():
    assert mymod.covered() == 1
CTESTEOF
        run_case "G coverage below floor -> FAIL rc=1" "$d" 1 'Below the .* floor' \
            AUDIT_FORCE_NO_COV=0 COV_TARGET=mymod MIN_COVERAGE_THRESHOLD=70
    else
        BAD_N=$((BAD_N + 1))
        printf '  [BAD] %-46s (could not install pytest-cov)\n' "G coverage below floor"
    fi

    d="$BASE/H_git_rebase"; mkdir -p "$d"
    cd "$d" || return 1
    git init -b main
    echo "initial" > file.txt; git add .; git commit -m "init"
    echo "change" > file.txt; git add .; git commit -m "local change"
    run_case "H git pull failure (no remote)" "$d" 0 'VERDICT: PASS' \
        AUDIT_FORCE_NO_GIT=0 AUDIT_SKIP_PULL=0
    cd - || return 1

    echo "--------------------------------------------------------------------------------"
    printf '  SELF-TEST TOTAL: %d ok, %d bad, %d skipped\n' "$OK_N" "$BAD_N" "$SKIP_N"
    echo "  Reports preserved in: $SELFTEST_REPORTS"
    echo "================================================================================"
    [ "$BAD_N" -eq 0 ]
}

AUDIT_DRY_RUN=0
if [ $# -gt 0 ]; then
    case "$1" in
        --self-test) run_self_test; exit $? ;;
        --dry-run)   AUDIT_DRY_RUN=1; shift ;;
    esac
fi

STASHED=false
FINAL_STATUS=0
LOG_FILE="${LOG_FILE:-repo_audit_$(date +%Y%m%d_%H%M%S).txt}"
MIN_COVERAGE_THRESHOLD="${MIN_COVERAGE_THRESHOLD:-70}"
AUDIT_STRICT="${AUDIT_STRICT:-1}"
AUDIT_REQUIRE_TESTS="${AUDIT_REQUIRE_TESTS:-0}"
AUDIT_SKIP_PULL="${AUDIT_SKIP_PULL:-0}"
AUDIT_HTML_COV="${AUDIT_HTML_COV:-0}"
COV_TARGET_OVERRIDE="${COV_TARGET:-}"
AUDIT_DRY_RUN="${AUDIT_DRY_RUN:-0}"

touch "$LOG_FILE" || { echo "FATAL: cannot write log: $LOG_FILE" >&2; exit 2; }
exec 3>&1 4>&2
exec 1> >(tee -a "$LOG_FILE") 2>&1

cleanup() {
    exec 1>&3 2>&4
    wait
    rm -f ./.coverage ./.coverage.*
    if [ "${STASHED:-false}" = "true" ]; then
        echo "[TRAP] Restoring stashed changes..." >&2
        git stash pop || echo "[WARNING] Stash pop conflicted." >&2
    fi
}
trap cleanup EXIT

log_info()  { echo "[INFO] $(date +%H:%M:%S) $*"; }
log_warn()  { echo "[WARNING] $(date +%H:%M:%S) $*"; }
log_error() { echo "[ERROR] $(date +%H:%M:%S) $*"; }

log_info "================================================================================"
log_info "          ONE-SHOT GIT PULL & CODEBASE AUDIT REPORT (v48.0)                    "
log_info "================================================================================"
log_info "Date: $(date)  Directory: $(pwd)"
log_info "Log: $LOG_FILE  Coverage floor: ${MIN_COVERAGE_THRESHOLD}%"
log_info "================================================================================"

log_info ">>> [1/6] GIT WORKING TREE PREPARATION"
export GIT_TERMINAL_PROMPT=0
if [ "${AUDIT_FORCE_NO_GIT:-0}" != "1" ] && git rev-parse --is-inside-work-tree; then
    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD || echo '')"
    HEAD_OK=false
    git rev-parse --verify -q HEAD && HEAD_OK=true
    DETACHED=false; [ "$CURRENT_BRANCH" = "HEAD" ] && DETACHED=true
    UNBORN=false; [ "$HEAD_OK" = false ] && UNBORN=true

    if [ "${CI:-}" = "true" ] || [ "$DETACHED" = true ] || [ "$AUDIT_SKIP_PULL" = "1" ] || [ "$AUDIT_DRY_RUN" = "1" ]; then
        log_info "Skipping pull (CI=${CI:-unset} detached=$DETACHED skip=$AUDIT_SKIP_PULL dry=$AUDIT_DRY_RUN)"
    else
        if [ "$HEAD_OK" = true ] && ! git diff-index --quiet HEAD --; then
            log_info "Dirty tree; stashing before pull..."
            git stash save -u "auto_audit_$(date +%s)" && STASHED=true || log_warn "stash failed"
        fi
        log_info "Pulling (ff-only)..."
        if git pull --quiet --ff-only origin "$CURRENT_BRANCH"; then
            log_info "Latest: $(git log -1 --oneline)"
        else
            log_warn "ff-only failed; trying rebase..."
            if git pull --quiet --rebase origin "$CURRENT_BRANCH"; then
                log_info "Rebase OK."
            else
                log_error "pull failed; aborting rebase."
                git rebase --abort || true
                if [ -d "$(git rev-parse --git-path rebase-merge)" ] || \
                   [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
                    log_error "Repo left in rebase state! Aborting to prevent corruption."
                    FINAL_STATUS=2
                    exit "$FINAL_STATUS"
                fi
            fi
        fi
    fi
else
    log_info "Not inside a git repository (or force-no-git)."
fi

log_info ">>> [2/6] PYTHON CODE LINTING & SYNTAX ANALYSIS"
log_info "--- [2A] py_compile ---"
if command -v python3; then
    run_with_timeout 30 python3 - <<'PYEOF'
import os, py_compile
IGNORE = {'.git','venv','.venv','env','__pycache__','node_modules','build','dist','.pytest_cache','.mypy_cache'}
files, errors = [], 0
for root, dirs, names in os.walk('.'):
    dirs[:] = [d for d in dirs if d not in IGNORE]
    for n in names:
        if n.endswith('.py'): files.append(os.path.join(root, n))
for p in files:
    try: py_compile.compile(p, doraise=True)
    except py_compile.PyCompileError as e:
        print(f'  [SYNTAX ERROR] {e}'); errors += 1
if errors == 0: print(f'  [OK] {len(files)} Python file(s) compiled cleanly.')
else: print(f'  [SUMMARY] {errors} file(s) contain syntax errors.')
PYEOF
fi

log_info "--- [2B] Risky constructs ---"
grep_py -E "(except[[:space:]]*:|print[[:space:]]*\(|import[[:space:]]+pdb|breakpoint[[:space:]]*\(|serial\.Serial[[:space:]]*\()" | \
awk -F: '{ if ($1 ~ /\.py$/) { rest=substr($0,index($0,$3)); print "  [LINT] " $1 " (Line " $2 "): " rest } }' | head -n 30

log_info "--- [2C] Files over 400 lines ---"
if command -v python3; then
    run_with_timeout 30 python3 - <<'PYEOF'
import os
IGNORE = {'.git','venv','.venv','env','__pycache__','node_modules','build','dist','.pytest_cache','.mypy_cache'}
flagged = 0
for root, dirs, names in os.walk('.'):
    dirs[:] = [d for d in dirs if d not in IGNORE]
    for n in names:
        if not n.endswith('.py'): continue
        p = os.path.join(root, n)
        try:
            with open(p, encoding='utf-8', errors='ignore') as fh: cnt = sum(1 for _ in fh)
        except OSError: continue
        if cnt > 400: print(f'  [SIZE WARNING] {p}: {cnt} lines'); flagged += 1
if flagged == 0: print('  [OK] No Python file exceeds 400 lines.')
PYEOF
fi

log_info ">>> [3/6] LOGIC, SECURITY & HARDCODED CREDENTIALS"
log_info "--- [3A] Secrets / hardcoded paths ---"
grep_py -E "(api_key[[:space:]]*=[[:space:]]*['\"][a-zA-Z0-9_-]{8,}['\"]|secret[[:space:]]*=[[:space:]]*['\"][a-zA-Z0-9_-]{8,}['\"]|bearer[[:space:]]+[a-zA-Z0-9._-]+|/home/[a-zA-Z0-9_-]+|C:\\\\Users\\\\[a-zA-Z0-9_-]+)" | \
awk -F: '{ if ($1 ~ /\.py$/) { rest=substr($0,index($0,$3)); msg=(length(rest)>80)?substr(rest,1,80)"...":rest; print "  [SECURITY] " $1 " (Line " $2 "): " msg } }' | head -n 20

log_info "--- [3B] Mutable default args (AST) ---"
if command -v python3; then
    run_with_timeout 30 python3 - <<'PYEOF'
import ast, os
IGNORE = {'.git','venv','.venv','env','__pycache__','node_modules','build','dist','.pytest_cache','.mypy_cache'}
flagged = 0
for root, dirs, names in os.walk('.'):
    dirs[:] = [d for d in dirs if d not in IGNORE]
    for n in names:
        if not n.endswith('.py'): continue
        p = os.path.join(root, n)
        try:
            with open(p, encoding='utf-8', errors='ignore') as fh: tree = ast.parse(fh.read(), filename=p)
        except (OSError, SyntaxError, ValueError): continue
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                defaults = list(node.args.defaults) + list(node.args.kw_defaults)
                if any(isinstance(d, (ast.List, ast.Dict, ast.Set)) for d in defaults):
                    print(f"  [LOGIC RISK] {p} (Line {node.lineno}): mutable default in '{node.name}'")
                    flagged += 1
if flagged == 0: print('  [OK] No mutable default arguments detected.')
PYEOF
fi

log_info ">>> [4/6] UX & CLI FEEDBACK AUDIT"
log_info "--- [4A] Blocking input / abrupt exits ---"
grep_py -E "(input[[:space:]]*\(|sys\.exit[[:space:]]*\(|os\._exit[[:space:]]*\()" | \
awk -F: '{ if ($1 ~ /\.py$/) { rest=substr($0,index($0,$3)); print "  [UX] " $1 " (Line " $2 "): " rest } }' | head -n 15

log_info "--- [4B] External URL health (up to 5) ---"
if [ "${AUDIT_FORCE_NO_CURL:-0}" != "1" ] && command -v curl; then
    URLS="$(grep -rhoE 'https?://[a-zA-Z0-9._~:/?#@!$&'\''()*+,;=%-]+' \
        --exclude-dir=".git" --exclude-dir="venv" --exclude-dir=".venv" \
        --exclude-dir="node_modules" --exclude="*.txt" --exclude="*.md" . | \
        awk '{ gsub(/[.,;:)"\x27]+$/, "", $0); print }' | sort -u | head -n 5)"
    if [ -n "${URLS:-}" ]; then
        while IFS= read -r url; do
            [ -z "$url" ] && continue
            STATUS="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 3 "$url")"
            case "$STATUS" in
                2*|3*) echo "  [UX/API OK]   ($STATUS) $url" ;;
                *)     echo "  [UX/API FAIL] (${STATUS:-000}) $url" ;;
            esac
        done <<< "$URLS"
    else
        echo "  [INFO] No external URLs found to audit."
    fi
else
    echo "  [INFO] curl not installed; skipping URL checks."
fi

log_info ">>> [5/6] REPOSITORY METRICS & HYGIENE"
BIG="$(run_with_timeout 30 find . -type f -size +1M -not -path "*/.git/*" -not -path "*/venv/*" -not -path "*/.venv/*" -not -path "*/node_modules/*")"
if [ -n "${BIG:-}" ]; then
    printf '%s\n' "$BIG" | while IFS= read -r f; do
        printf '  [LARGE FILE] %s (%s bytes)\n' "$f" "$(wc -c < "$f" || echo '?')"
    done
else
    echo "  [OK] No files over 1 MiB."
fi
if [ -f .gitignore ]; then echo "  [HYGIENE OK] .gitignore present."; else echo "  [HYGIENE WARNING] No .gitignore."; fi

log_info ">>> [6/6] UNIT TESTS & COVERAGE"
TEST_STATE="skip"
TESTS_FOUND=false
if [ -d tests ] || [ -d test ]; then
    TESTS_FOUND=true
elif find . \( -name "test_*.py" -o -name "*_test.py" \) \
        -not -path "*/.git/*" -not -path "*/venv/*" -not -path "*/.venv/*" \
        -not -path "*/node_modules/*" | grep -q .; then
    TESTS_FOUND=true
fi

if [ "$TESTS_FOUND" = false ]; then
    log_info "No test files found. Skipping."
    TEST_STATE="skip"
elif ! command -v python3; then
    log_warn "python3 unavailable; SKIP."
    TEST_STATE="skip"
else
    export MOCK_HARDWARE=1
    export SERIAL_PORT="MOCK"

    HAS_PYTEST=false
    HAS_COV=false
    [ "${AUDIT_FORCE_NO_PYTEST:-0}" != "1" ] && python3 -c "import pytest" && HAS_PYTEST=true
    [ "${AUDIT_FORCE_NO_COV:-0}"    != "1" ] && python3 -c "import pytest_cov" && HAS_COV=true

    TEST_EXIT_CODE=1

    if [ "$HAS_PYTEST" = true ] && [ "$HAS_COV" = true ]; then
        log_info "Running pytest + pytest-cov..."

        if [ -n "$COV_TARGET_OVERRIDE" ]; then
            COV_TARGET="$COV_TARGET_OVERRIDE"
        else
            COV_TARGET="$(python3 - <<'PYEOF'
import os
IGNORE = {'.git','venv','.venv','env','build','dist','node_modules','tests','test','__pycache__'}
if os.path.isdir('src'):
    print('src')
else:
    for item in sorted(os.listdir('.')):
        if os.path.isdir(item) and not item.startswith('.') and item not in IGNORE:
            for _r,_d,files in os.walk(item):
                if any(f.endswith('.py') for f in files):
                    print(item); break
            else: continue
            break
PYEOF
)"
            [ -z "$COV_TARGET" ] && COV_TARGET="."
        fi
        log_info "Coverage target: $COV_TARGET"

        TMP_COV_OUT="$(mktemp -t audit_cov.XXXXXX || mktemp)"
        [ -f "$TMP_COV_OUT" ] || { TMP_COV_OUT="/tmp/audit_cov_$$.tmp"; touch "$TMP_COV_OUT"; }

        COV_ARGS=("--cov=$COV_TARGET" "--cov-report=term-missing" \
                  "--cov-fail-under=$MIN_COVERAGE_THRESHOLD")
        [ "$AUDIT_HTML_COV" = "1" ] && COV_ARGS+=("--cov-report=html:htmlcov")

        NO_COLOR=1 python3 -m pytest "${COV_ARGS[@]}" -v --tb=short 2>&1 | tee "$TMP_COV_OUT"
        TEST_EXIT_CODE=${PIPESTATUS[0]}

        echo ""
        log_info "--- [COVERAGE ANALYSIS] ---"

        TOTAL_LINE=$(grep -iE '^[[:space:]]*TOTAL[[:space:]]' "$TMP_COV_OUT" | head -n1)
        if [ -n "$TOTAL_LINE" ]; then
            COV_PCT=$(echo "$TOTAL_LINE" | grep -oE '[0-9]+%' | tail -n1 | tr -d '%')
            COV_STMTS=$(echo "$TOTAL_LINE" | awk '{print $2}')
        else
            COV_PCT=""
            COV_STMTS=""
        fi

        rm -f "$TMP_COV_OUT" ./.coverage ./.coverage.*

        case "$TEST_EXIT_CODE" in
            0)
                TEST_STATE="pass"
                if [ -n "$COV_PCT" ]; then
                    log_info "Coverage: ${COV_PCT}% (${COV_STMTS:-?} statements)"
                    log_info "Coverage meets the ${MIN_COVERAGE_THRESHOLD}% floor."
                fi
                ;;
            5)
                TEST_STATE="skip"
                log_info "pytest collected no tests (exit 5) — SKIP."
                ;;
            *)
                if [ -n "$COV_PCT" ]; then
                    log_info "Coverage: ${COV_PCT}% (${COV_STMTS:-?} statements)"
                fi
                log_warn "Coverage below the ${MIN_COVERAGE_THRESHOLD}% floor."
                TEST_STATE="fail"
                ;;
        esac

    elif [ "$HAS_PYTEST" = true ]; then
        log_info "pytest-cov not installed; running pytest without coverage..."
        python3 -m pytest -v --tb=short
        TEST_EXIT_CODE=$?
        case "$TEST_EXIT_CODE" in
            0) TEST_STATE="pass" ;;
            5) TEST_STATE="skip" ;;
            *) TEST_STATE="fail" ;;
        esac
    else
        log_info "pytest not installed; using unittest fallback."
        run_with_timeout 30 python3 - <<'PYEOF'
import os, sys, unittest, importlib.util, traceback
test_files = []
IGNORE = {'.git','venv','.venv','env','__pycache__','node_modules','build','dist','.pytest_cache','.mypy_cache'}
for root, dirs, files in os.walk('.'):
    dirs[:] = [d for d in dirs if d not in IGNORE]
    for f in files:
        if (f.startswith('test_') and f.endswith('.py')) or f.endswith('_test.py'):
            test_files.append(os.path.join(root, f))
if not test_files:
    print('  [INFO] No test files found by fallback runner.'); sys.exit(5)
sys.path.insert(0, os.getcwd())
loader = unittest.TestLoader(); suite = unittest.TestSuite(); errs = 0
for path in test_files:
    mod_name = 'testmod_' + ''.join(c if c.isalnum() else '_' for c in path)
    try:
        spec = importlib.util.spec_from_file_location(mod_name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        t = loader.loadTestsFromModule(module)
        if t.countTestCases(): suite.addTests(t)
    except Exception as e:
        errs += 1; print(f'  [IMPORT ERROR] {path}: {e}'); traceback.print_exc()
if suite.countTestCases() == 0 and errs == 0:
    print('  [INFO] Test files present but 0 test cases — SKIP.'); sys.exit(5)
r = unittest.TextTestRunner(verbosity=2).run(suite)
if errs: sys.exit(2)
sys.exit(0 if r.wasSuccessful() else 1)
PYEOF
        TEST_EXIT_CODE=$?
        case "$TEST_EXIT_CODE" in
            0) TEST_STATE="pass" ;;
            5) TEST_STATE="skip" ;;
            *) TEST_STATE="fail" ;;
        esac
    fi

    echo ""
    case "$TEST_STATE" in
        pass) log_info "TEST RESULT: PASSED" ;;
        skip) log_info "TEST RESULT: SKIPPED (no tests collected — not a failure)" ;;
        *)    log_error "TEST RESULT: FAILED (exit code ${TEST_EXIT_CODE:-?})" ;;
    esac
fi

if [ "$TEST_STATE" = "skip" ] && [ "$AUDIT_REQUIRE_TESTS" = "1" ]; then
    log_warn "AUDIT_REQUIRE_TESTS=1 — promoting SKIP -> POLICY_FAIL."
    TEST_STATE="fail_policy"
fi

case "$TEST_STATE" in
    fail)        [ "$AUDIT_STRICT" = "1" ] && FINAL_STATUS=1 ;;
    fail_policy) [ "$AUDIT_STRICT" = "1" ] && FINAL_STATUS=3 ;;
esac

echo ""
log_info "================================================================================"
if [ "$FINAL_STATUS" -eq 0 ]; then
    if [ "$TEST_STATE" = "skip" ]; then
        log_info "AUDIT VERDICT: PASS (with test SKIP)    (report: $LOG_FILE)"
    else
        log_info "AUDIT VERDICT: PASS    (report: $LOG_FILE)"
    fi
elif [ "$TEST_STATE" = "fail_policy" ]; then
    log_error "AUDIT VERDICT: POLICY_FAIL    (report: $LOG_FILE)"
else
    log_error "AUDIT VERDICT: FAIL    (report: $LOG_FILE)"
fi
log_info "================================================================================"

exit "$FINAL_STATUS"
