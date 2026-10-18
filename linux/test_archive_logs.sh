#!/bin/bash
unset LAB1_MAX_COMPRESSION

script_dir=$(cd "$(dirname "$0")" && pwd)
main_script="$script_dir/archive_logs.sh"

work_dir=$(mktemp -d)
disk_dir="$work_dir/disk"
mkdir "$disk_dir"
disk_mounted=0

cleanup() {
    if [ "$disk_mounted" = "1" ]; then
        sudo umount "$disk_dir"
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

echo "Creating a 1 GB virtual disk (sudo may ask for your password)"
if ! sudo mount -t tmpfs -o size=1G,uid=$(id -u),gid=$(id -g) tmpfs "$disk_dir"; then
    echo "Error: cannot create a virtual disk" >&2
    exit 1
fi
disk_mounted=1
echo "Virtual disk: 1 GB tmpfs at $disk_dir"

log_dir="$disk_dir/log"
backup_dir="$work_dir/backup"
output_file="$work_dir/output.txt"

disk_line=$(df -P -k "$disk_dir" | tail -n 1)
disk_total_kb=$(echo "$disk_line" | awk '{print $2}')
file_kb=$(( disk_total_kb * 8 / 100 ))

echo "One log file: $(( file_kb / 1024 )) MB (8% of the disk)"
echo

tests_total=0
tests_passed=0

create_file() {
    yes "2026-10-12 12:00:00 INFO user=42 action=login status=ok" | head -c "${2}K" > "$1"
    touch -d "$3 days ago" "$1"
}

create_log_files() {
    count=$1
    for i in $(seq 1 "$count"); do
        name="app_$(printf '%02d' "$i").log"
        create_file "$log_dir/$name" "$file_kb" "$i"
    done
}

get_disk_percent() {
    disk_line=$(df -P -k "$disk_dir" | tail -n 1)
    disk_total_kb=$(echo "$disk_line" | awk '{print $2}')
    disk_used_kb=$(echo "$disk_line" | awk '{print $3}')
    disk_percent=$(( disk_used_kb * 100 / disk_total_kb ))
}

fail() {
    echo "    failed: $1"
    test_failed=1
}

start_test() {
    tests_total=$(( tests_total + 1 ))
    echo "Test $tests_total: $1"
    rm -rf "$log_dir" "$backup_dir"
    mkdir "$log_dir" "$backup_dir"
    test_failed=0
}

show_log_size() {
    log_kb=$(du -s -k "$log_dir" | cut -f 1)
    files_before=$(ls "$log_dir" | wc -l)
    get_disk_percent
    echo "    prepared: $files_before files, $(( log_kb / 1024 )) MB, disk usage $disk_percent%"
    if [ "$log_kb" -lt $(( 512 * 1024 )) ]; then
        fail "log folder is smaller than 0.5 GB"
    fi
}

run_main_script() {
    echo "\$ archive_logs.sh $*" >> "$output_file"
    "$main_script" "$@" >> "$output_file" 2>&1
    exit_code=$?
}

check_exit_code() {
    if [ "$exit_code" -ne "$1" ]; then
        fail "exit code $exit_code, expected $1"
    fi
}

check_usage_below() {
    get_disk_percent
    if [ $(( disk_used_kb * 100 )) -gt $(( disk_total_kb * $1 )) ]; then
        fail "disk usage is $disk_percent%, expected at most $1%"
    fi
}

check_no_archive() {
    if [ "$(ls "$backup_dir" | wc -l)" -ne 0 ]; then
        fail "an archive was created but should not have been"
    fi
}

check_files_left() {
    files_left=$(ls "$log_dir" | wc -l)
    if [ "$files_left" -ne "$1" ]; then
        fail "$files_left files left in the log folder, expected $1"
    fi
}

check_archive() {
    archive_type=$1
    shift

    if [ "$(ls "$backup_dir" | wc -l)" -ne 1 ]; then
        fail "there must be exactly one archive in $backup_dir"
        return
    fi
    archive_path="$backup_dir/$(ls "$backup_dir")"

    if [ "$archive_type" = "lzma" ]; then
        expected_ending=".tar.lzma"
        tar --lzma -t -f "$archive_path" | sort > "$work_dir/actual.txt"
    else
        expected_ending=".tar.gz"
        tar --gzip -t -f "$archive_path" | sort > "$work_dir/actual.txt"
    fi

    case "$archive_path" in
        *"$expected_ending") ;;
        *) fail "archive $(basename "$archive_path") must end with $expected_ending" ;;
    esac

    rm -f "$work_dir/expected.txt"
    for name in "$@"; do
        echo "$name" >> "$work_dir/expected.txt"
    done
    sort -o "$work_dir/expected.txt" "$work_dir/expected.txt"

    if ! diff -q "$work_dir/expected.txt" "$work_dir/actual.txt" > /dev/null; then
        fail "wrong files in the archive"
        echo "      expected:   $(tr '\n' ' ' < "$work_dir/expected.txt")"
        echo "      in archive: $(tr '\n' ' ' < "$work_dir/actual.txt")"
    fi

    for name in "$@"; do
        if [ -e "$log_dir/$name" ]; then
            fail "$name was archived but not deleted"
        fi
    done
}

finish_test() {
    if [ "$test_failed" -eq 0 ]; then
        echo "    OK"
        tests_passed=$(( tests_passed + 1 ))
    else
        echo "    FAILED, archive_logs.sh output:"
        while IFS= read -r line; do
            echo "    | $line"
        done < "$output_file"
    fi
    rm -f "$output_file"
    echo
}

start_test "below threshold - nothing to do"
create_log_files 8
show_log_size
run_main_script "$log_dir" 70 "$backup_dir"
check_exit_code 0
check_no_archive
check_files_left 8
finish_test

start_test "above 70% - oldest files archived"
create_log_files 10
show_log_size
run_main_script "$log_dir" 70 "$backup_dir"
check_exit_code 0
check_usage_below 70
check_archive gz app_10.log app_09.log
check_files_left 8
finish_test

start_test "one big old file - only it is archived"
create_file "$log_dir/huge.log" $(( file_kb * 30 / 8 )) 30
create_log_files 6
show_log_size
run_main_script "$log_dir" 70 "$backup_dir"
check_exit_code 0
check_usage_below 70
check_archive gz huge.log
check_files_left 6
finish_test

start_test "other threshold: 55%"
create_log_files 8
show_log_size
run_main_script "$log_dir" 55 "$backup_dir"
check_exit_code 0
check_usage_below 55
check_archive gz app_08.log app_07.log
check_files_left 6
finish_test

start_test "LAB1_MAX_COMPRESSION=1 - lzma compression"
create_log_files 10
show_log_size
export LAB1_MAX_COMPRESSION=1
run_main_script "$log_dir" 70 "$backup_dir"
unset LAB1_MAX_COMPRESSION
check_exit_code 0
check_usage_below 70
check_archive lzma app_10.log app_09.log
check_files_left 8
finish_test

echo "Passed $tests_passed of $tests_total tests"
if [ "$tests_passed" -ne "$tests_total" ]; then
    exit 1
fi
exit 0
