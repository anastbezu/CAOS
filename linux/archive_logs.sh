#!/bin/bash

error_exit() {
    echo "Error: $1" >&2
    exit 1
}

get_disk_usage() {
    disk_line=$(df -P -k "$log_dir" | tail -n 1)
    disk_total_kb=$(echo "$disk_line" | awk '{print $2}')
    disk_used_kb=$(echo "$disk_line" | awk '{print $3}')
    mount_point=$(echo "$disk_line" | awk '{print $6}')
}

percent() {
    tenths=$(( $1 * 1000 / $2 ))
    echo "$(( tenths / 10 )).$(( tenths % 10 ))"
}

log_dir="$1"
threshold="$2"
backup_dir="$3"

if [ -z "$log_dir" ]; then
    echo "Usage: $0 <log_dir> [threshold_percent=70] [backup_dir]"
    exit 1
fi

if [ ! -d "$log_dir" ]; then
    error_exit "folder '$log_dir' not found"
fi

if [ -z "$threshold" ]; then
    threshold=70
fi

if ! echo "$threshold" | grep -q -x -E '0|[1-9][0-9]*'; then
    error_exit "threshold must be a whole number from 0 to 100, got '$threshold'"
fi
if [ "$threshold" -gt 100 ]; then
    error_exit "threshold must be a whole number from 0 to 100, got '$threshold'"
fi

if [ -z "$backup_dir" ]; then
    backup_dir="$(dirname "$log_dir")/backup"
fi

get_disk_usage
limit_kb=$(( disk_total_kb * threshold / 100 ))
usage_before=$(percent "$disk_used_kb" "$disk_total_kb")

echo "Folder:       $log_dir"
echo "Folder limit: $(( disk_total_kb / 1024 )) MB (filesystem mounted at $mount_point)"
if [ "$mount_point" = "/" ]; then
    echo "Warning: $log_dir is not on a separate filesystem, its limit is the whole system disk" >&2
fi
echo "Disk usage:   $(( disk_used_kb / 1024 )) MB of $(( disk_total_kb / 1024 )) MB ($usage_before%), threshold $threshold%"

if [ "$disk_used_kb" -le "$limit_kb" ]; then
    echo "Below threshold, nothing to do."
    exit 0
fi

need_to_free_kb=$(( disk_used_kb - limit_kb ))
echo "Threshold exceeded, need to free at least $(( need_to_free_kb / 1024 )) MB."

sorted_list=$(mktemp)
ls -t -r "$log_dir" > "$sorted_list"

files_to_archive=()
freed_kb=0

while IFS= read -r file_name; do
    if [ "$freed_kb" -ge "$need_to_free_kb" ]; then
        break
    fi
    if [ ! -f "$log_dir/$file_name" ]; then
        continue
    fi

    file_kb=$(du -k "$log_dir/$file_name" | cut -f 1)

    files_to_archive+=("$file_name")
    freed_kb=$(( freed_kb + file_kb ))
done < "$sorted_list"

rm -f "$sorted_list"

files_count=${#files_to_archive[@]}

if [ "$files_count" -eq 0 ]; then
    echo "There are no files to archive in this folder." >&2
    exit 2
fi

echo "Archiving $files_count oldest file(s), $(( freed_kb / 1024 )) MB:"
for file_name in "${files_to_archive[@]}"; do
    echo "  $file_name"
done

if [ "$LAB1_MAX_COMPRESSION" = "1" ]; then
    compress_option="--lzma"
    archive_extension="tar.lzma"
else
    compress_option="--gzip"
    archive_extension="tar.gz"
fi

mkdir -p "$backup_dir" || error_exit "cannot create folder '$backup_dir'"
archive_path="$backup_dir/logs_$(date +%Y-%m-%d_%H-%M-%S).$archive_extension"

if ! tar -c "$compress_option" -f "$archive_path" -C "$log_dir" -- "${files_to_archive[@]}"; then
    rm -f "$archive_path"
    error_exit "tar could not create the archive, no files were deleted"
fi

archive_kb=$(du -k "$archive_path" | cut -f 1)
echo "Archive:      $archive_path ($(( archive_kb / 1024 )) MB)"

for file_name in "${files_to_archive[@]}"; do
    rm -f "$log_dir/$file_name"
done
echo "Deleted:      $files_count file(s)"

get_disk_usage
usage_after=$(percent "$disk_used_kb" "$disk_total_kb")
echo "Disk usage:   $usage_before% -> $usage_after%"

if [ "$disk_used_kb" -gt "$limit_kb" ]; then
    echo "Warning: still above $threshold%, the rest of the space is used outside $log_dir" >&2
    exit 2
fi

exit 0
