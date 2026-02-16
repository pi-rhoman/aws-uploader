#!/bin/bash

while getopts ":f:" flag
do
	case "${flag}" in
		f) fragments=${OPTARG};; 
	esac
done
shift $((OPTIND - 1))
BACKUP_FILE=`realpath $1`

# Get the hash of the file
MD5=`md5sum -b $BACKUP_FILE`


# Split the file into fragments
if [ ! -d $fragments ]; then
	printf '%s\n' "fragments directory does not exist" >&2
	exit 1
fi
# change directory to the fragmetns
cd $fragments
split -d -n 200 $BACKUP_FILE `basename $BACKUP_FILE`. 

#aws s3api create-multipart-upload --bucket liams-computer-backup --key `basename $BACKUP_FILE`

