#!/usr/bin/env bats
# Unit Tests for Rate Limiting Logic

load '../helpers/test_helper'

# Source ralph functions (we need to extract these first)
setup() {
    # Source helper functions
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"

    # Set up environment with .ralph/ subfolder structure
    export RALPH_DIR=".ralph"
    export MAX_CALLS_PER_HOUR=100
    export CALL_COUNT_FILE="$RALPH_DIR/.call_count"
    export TIMESTAMP_FILE="$RALPH_DIR/.last_reset"

    # Create temp test directory
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    mkdir -p "$RALPH_DIR"

    # Initialize files
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
}

teardown() {
    # Clean up
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper function: can_make_call (extracted from ralph_loop.sh)
can_make_call() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi

    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1  # Cannot make call
    else
        return 0  # Can make call
    fi
}

# Helper function: increment_call_counter (extracted from ralph_loop.sh)
increment_call_counter() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi

    ((calls_made++))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

# Test 1: can_make_call returns success when under limit
@test "can_make_call returns success when under limit" {
    echo "50" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test 2: can_make_call returns success when exactly at limit minus 1
@test "can_make_call returns success when at limit minus 1" {
    echo "99" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test 3: can_make_call returns failure when at limit
@test "can_make_call returns failure when at limit" {
    echo "100" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_failure
}

# Test 4: can_make_call returns failure when over limit
@test "can_make_call returns failure when over limit" {
    echo "150" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_failure
}

# Test 5: can_make_call returns success when file doesn't exist (0 calls)
@test "can_make_call returns success when call count file missing" {
    rm -f "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test 6: increment_call_counter increases from 0
@test "increment_call_counter increases from 0 to 1" {
    echo "0" > "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "1"
    assert_equal "$(cat $CALL_COUNT_FILE)" "1"
}

# Test 7: increment_call_counter increases from middle value
@test "increment_call_counter increases from 42 to 43" {
    echo "42" > "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "43"
    assert_equal "$(cat $CALL_COUNT_FILE)" "43"
}

# Test 8: increment_call_counter works near limit
@test "increment_call_counter increases from 99 to 100" {
    echo "99" > "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "100"
    assert_equal "$(cat $CALL_COUNT_FILE)" "100"
}

# Test 9: increment_call_counter works when file missing
@test "increment_call_counter creates file and sets to 1 when missing" {
    rm -f "$CALL_COUNT_FILE"

    result=$(increment_call_counter)
    assert_equal "$result" "1"
    assert_equal "$(cat $CALL_COUNT_FILE)" "1"
}

# Test 10: Rate limit with different MAX_CALLS value (50)
@test "can_make_call respects MAX_CALLS_PER_HOUR of 50" {
    echo "49" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=50

    run can_make_call
    assert_success

    echo "50" > "$CALL_COUNT_FILE"
    run can_make_call
    assert_failure
}

# Test 11: Rate limit with different MAX_CALLS value (25)
@test "can_make_call respects MAX_CALLS_PER_HOUR of 25" {
    echo "24" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=25

    run can_make_call
    assert_success

    echo "25" > "$CALL_COUNT_FILE"
    run can_make_call
    assert_failure
}

# Test 12: Counter persistence across multiple increments
@test "counter persists correctly across multiple increments" {
    echo "0" > "$CALL_COUNT_FILE"

    result1=$(increment_call_counter)  # 1
    result2=$(increment_call_counter)  # 2
    result3=$(increment_call_counter)  # 3
    result4=$(increment_call_counter)  # 4

    assert_equal "$result4" "4"
    assert_equal "$(cat $CALL_COUNT_FILE)" "4"
}

# Test 13: Call count file contains only a number
@test "call count file contains valid integer" {
    run increment_call_counter

    # Check the call count file contains a valid integer
    value=$(cat "$CALL_COUNT_FILE")
    [[ "$value" =~ ^[0-9]+$ ]] || {
        echo "Call count file does not contain valid integer: $value"
        return 1
    }
}

# Test 14: Can make call with zero calls
@test "can_make_call returns success with zero calls made" {
    echo "0" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    run can_make_call
    assert_success
}

# Test 15: Edge case - very large MAX_CALLS value
@test "can_make_call works with large MAX_CALLS value" {
    echo "5000" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=10000

    run can_make_call
    assert_success
}

# --- Regression tests for monitor call counter display bug ---
# The monitor reads .call_count from disk. Previously, execute_claude_code()
# incremented in a local variable and only wrote on success (exit code 0).
# This meant the monitor always showed stale values and failed calls were never counted.

# Test 16: increment_call_counter writes to disk immediately (not deferred)
@test "increment_call_counter persists to disk immediately" {
    echo "5" > "$CALL_COUNT_FILE"

    # Call increment — should write to disk, not just return the value
    result=$(increment_call_counter)
    assert_equal "$result" "6"

    # Verify disk was updated (monitor reads from disk)
    assert_equal "$(cat "$CALL_COUNT_FILE")" "6"
}

# Test 17: Call count file reflects usage even if execution would fail
# Simulates the fix: counter is persisted BEFORE execution outcome is known
@test "call count persists before execution outcome is determined" {
    echo "10" > "$CALL_COUNT_FILE"

    # Increment (simulates what execute_claude_code now does at the start)
    calls_made=$(increment_call_counter)
    assert_equal "$calls_made" "11"

    # Simulate a failed execution (timeout, error, etc.)
    # Previously the counter would NOT be written here
    # Now it's already on disk from increment_call_counter
    assert_equal "$(cat "$CALL_COUNT_FILE")" "11"
}

# Test 18: Status JSON reflects call count from file after increment
@test "status JSON can read updated call count from file after increment" {
    echo "0" > "$CALL_COUNT_FILE"

    # Increment three times (3 API calls)
    increment_call_counter > /dev/null
    increment_call_counter > /dev/null
    increment_call_counter > /dev/null

    # Simulate what update_status does: read from CALL_COUNT_FILE
    local calls_from_file=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    assert_equal "$calls_from_file" "3"

    # Simulate status.json creation (what monitor reads)
    cat > "$RALPH_DIR/status.json" <<EOF
{
    "calls_made_this_hour": $calls_from_file,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR
}
EOF

    # Verify monitor would see correct value
    local display_value=$(jq -r '.calls_made_this_hour' "$RALPH_DIR/status.json")
    assert_equal "$display_value" "3"
}

# --- Account rotation tests ---
# CLAUDE_CONFIG_DIR is the env var the Claude CLI uses for its config directory.
# advance_account_rotation: reads current index, advances to next account,
# writes new index to disk. Returns 0 if rotated, 1 if all accounts exhausted.
# get_current_account_index: reads index from disk, defaults to 0.

# Helper: extracted versions of functions under test
get_current_account_index() {
    local idx_file="$RALPH_DIR/.current_account_index"
    if [[ -f "$idx_file" ]]; then
        cat "$idx_file"
    else
        echo "0"
    fi
}

advance_account_rotation() {
    # Reads global CLAUDE_CONFIG_DIRS array (matches ralph_loop.sh usage)
    local total=${#CLAUDE_CONFIG_DIRS[@]}
    local idx_file="$RALPH_DIR/.current_account_index"
    local current=0
    [[ -f "$idx_file" ]] && current=$(cat "$idx_file")
    local next=$(( (current + 1) % total ))
    echo "$next" > "$idx_file"
    [[ $next -ne 0 ]]  # return 0 (success) if rotated, 1 (exhausted) if wrapped
}

@test "get_current_account_index returns 0 when no state file exists" {
    rm -f "$RALPH_DIR/.current_account_index"
    result=$(get_current_account_index)
    assert_equal "$result" "0"
}

@test "get_current_account_index returns value from state file" {
    echo "2" > "$RALPH_DIR/.current_account_index"
    result=$(get_current_account_index)
    assert_equal "$result" "2"
}

@test "advance_account_rotation with 2 accounts at index 0 rotates to index 1" {
    local CLAUDE_CONFIG_DIRS=("$HOME/.claude" "$HOME/.claude-account2")
    echo "0" > "$RALPH_DIR/.current_account_index"

    run advance_account_rotation CLAUDE_CONFIG_DIRS
    assert_success  # return 0 = rotated successfully

    assert_equal "$(cat "$RALPH_DIR/.current_account_index")" "1"
}

@test "advance_account_rotation at last account wraps and signals exhausted" {
    local CLAUDE_CONFIG_DIRS=("$HOME/.claude" "$HOME/.claude-account2")
    echo "1" > "$RALPH_DIR/.current_account_index"

    run advance_account_rotation CLAUDE_CONFIG_DIRS
    assert_failure  # return 1 = all accounts exhausted (wrapped to 0)

    assert_equal "$(cat "$RALPH_DIR/.current_account_index")" "0"
}

@test "advance_account_rotation with 3 accounts advances sequentially" {
    local CLAUDE_CONFIG_DIRS=("$HOME/.claude" "$HOME/.claude-account2" "$HOME/.claude-account3")
    echo "1" > "$RALPH_DIR/.current_account_index"

    run advance_account_rotation CLAUDE_CONFIG_DIRS
    assert_success  # index 2, not yet exhausted

    assert_equal "$(cat "$RALPH_DIR/.current_account_index")" "2"
}
