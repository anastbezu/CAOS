#!/bin/bash
PATH="$PATH:/usr/sbin:/sbin"
unset LAB1_MAX_COMPRESSION

script_dir=$(cd "$(dirname "$0")" && pwd)
this_script="$script_dir/$(basename "$0")"
main_script="$script_dir/archive_logs.sh"

if [ "$LAB1_IN_NAMESPACE" != "1" ]; then
    probe_dir=$(mktemp -d)
    if unshare --map-root-user --mount mount -t tmpfs tmpfs "$probe_dir" 2> /dev/null; then
        rmdir "$probe_dir"
        export LAB1_IN_NAMESPACE=1
        exec unshare --map-root-user --mount bash "$this_script"
    fi
    rmdir "$probe_dir"
fi

work_dir=$(mktemp -d)
disk_image="$work_dir/disk.img"
disk_dir="$work_dir/disk"
mkdir "$disk_dir"

disk_method=""
loop_device=""

cleanup() {
    if [ "$disk_method" = "tmpfs" ]; then
        umount "$disk_dir"
    fi
    if [ "$disk_method" = "udisks" ]; then
        udisksctl unmount --no-user-interaction -b "$loop_device" > /dev/null
    fi
    if [ -n "$loop_device" ]; then
        udisksctl loop-delete --no-user-interaction -b "$loop_device" > /dev/null
    fi
    if [ "$disk_method" = "sudo" ]; then
        sudo umount "$disk_dir"
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

mount_with_udisks() {
    loop_device=$(udisksctl loop-setup --no-user-interaction -f "$disk_image" 2> /dev/null | grep -o '/dev/loop[0-9]*')
    if [ -z "$loop_device" ]; then
        return 1
    fi

    udisksctl mount --no-user-interaction -b "$loop_device" > /dev/null 2>&1

    for attempt in 1 2 3 4 5; do
        mount_point=$(findmnt -n -o TARGET --source "$loop_device")
        if [ -n "$mount_point" ]; then
            disk_dir="$mount_point"
            return 0
        fi
        sleep 1
    done
    return 1
}

if [ "$LAB1_IN_NAMESPACE" = "1" ]; then
    if mount -t tmpfs -o size=1G tmpfs "$disk_dir"; then
        disk_method="tmpfs"
        echo "Virtual disk: 1 GB tmpfs in a user namespace (no root)"
    fi
else
    truncate -s 1G "$disk_image"
    mkfs.ext4 -q -F -m 0 -E root_owner="$(id -u):$(id -g)" "$disk_image"

    if mount_with_udisks; then
        disk_method="udisks"
        echo "Virtual disk: 1 GB ext4 image mounted with udisksctl (no root) at $disk_dir"
    else
        echo "Cannot create a disk without root, trying sudo mount (may ask for a password)"
        if sudo mount -o loop "$disk_image" "$disk_dir"; then
            disk_method="sudo"
            echo "Virtual disk: 1 GB ext4 image mounted with sudo at $disk_dir"
        fi
    fi
fi

if [ -z "$disk_method" ]; then
    echo "Error: cannot create a virtual disk" >&2
    exit 1
fi

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
