while true; do

	echo "Enter the path to the folder: "
	read path
	
	if [ -z "$path" ]; then
		echo "A path was not entered"
		continue
	fi

	if [ ! -e "$path" ]; then
		echo "Non-existent path"
		continue
	fi 

	if [ ! -d "$path" ]; then
		echo "Enter a path to a folder, not a file"
		continue
	fi
	
	if [[ ! "$path" =~ /log$ ]]; then
		echo "Path mast end with /log"
		continue
	fi

	break
done

echo "Valid path. Folder found"

dir_mem_kb=$(du -sk "$path" | awk '{print $1}')
total_mem_kb=$(df -k / |awk 'NR==2 {print $2}')
percent_dir_mem=$((dir_mem_kb*100 / total_mem_kb))
echo "Folder size: $percent_dir_mem%"

while true; do
	echo "Enter threshold (%): "
	read threshold
	if (( threshold <= 0 || threshold >= 1000)); then
		echo "Invalid threshold"
		continue
	fi
	break
done
	

